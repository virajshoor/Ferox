# Physics

Ferox ships its own rigid-body physics in the `FeroxPhysics` module. It does not wrap a third-party library. There are two worlds: `PhysicsWorld2D` for the XY plane and `PhysicsWorld3D` for full 3D. They share a solver design and a `SolverSettings` type. An ECS bridge, `PhysicsSystem2D` and `PhysicsSystem3D`, maps entities with physics components onto bodies, writes poses back into `Transform`, and publishes collision events. The solver is sequential-impulse, with warm starting, Coulomb friction, speculative contacts and sleep islands. The narrowphase is deliberately limited, and several pairs are approximated. Behaviour is covered by `Tests/FeroxPhysicsTests` (both worlds and the ECS bridge). Those tests have not yet been run on a Swift toolchain, so this document cites no test results and no measurements.

Entities and components are described in [06-Scene-and-Entities.md](06-Scene-and-Entities.md). Fixed-step timing is in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md).

## Contents

1. [Status and scope](#1-status-and-scope)
2. [Algorithm](#2-algorithm)
3. [Solver settings](#3-solver-settings)
4. [Materials and collision filtering](#4-materials-and-collision-filtering)
5. [Bodies](#5-bodies)
6. [Shapes](#6-shapes)
7. [Joints](#7-joints)
8. [Queries](#8-queries)
9. [Contact events](#9-contact-events)
10. [ECS integration](#10-ecs-integration)
11. [Character controller](#11-character-controller)
12. [Debug visualisation](#12-debug-visualisation)
13. [Code examples](#13-code-examples)
14. [Limitations](#14-limitations)
15. [Validation status](#15-validation-status)
16. [Related documents](#16-related-documents)

## 1. Status and scope

| Area | Status |
| --- | --- |
| 2D bodies, shapes, joints, queries | Implemented: `World2D.swift`, `Collision2D.swift`. |
| 3D bodies, shapes, joints, queries | Implemented: `World3D.swift`, `Collision3D.swift`. |
| ECS bridge and components | Implemented: `PhysicsSystems.swift`, `PhysicsComponents.swift`. |
| Shared types, broadphase, union-find | Implemented: `Common.swift`. |
| Continuous collision detection | Implemented for fast dynamic bodies against static and kinematic shapes: `World3D.swift`, `World2D.swift`. See [section 2.1](#21-the-step). |
| Convex hulls for 3D shapes | **Not implemented.** |
| Exact box-against-mesh contacts | **Not implemented.** Approximated. |
| Multi-threaded solver | **Not implemented.** The step is single-threaded. |

## 2. Algorithm

### 2.1 The step

`step(_:)` is the same in both worlds. A call with `dt <= 0` does nothing.

1. **Integrate velocities.** Awake dynamic bodies gain gravity (scaled by `gravityScale`) and `force * invMass`, then damping is applied. Forces and torques are cleared.
2. **Detect collisions.** The broadphase proposes pairs, and the narrowphase builds a manifold for each shape pair. Contacts are created, refreshed or removed. Begin and end events are recorded, and touching contacts wake sleeping bodies.
3. **Prepare and warm start.** Each active contact and joint computes its effective masses, position bias and restitution bias. Impulses from the previous step are re-applied if `warmStarting` is on.
4. **Solve.** `velocityIterations` (at least 1) sweeps run over joints, then contacts.
5. **Integrate positions.** Fast dynamic bodies are first clamped by continuous collision (below). Per-step translation and rotation are then clamped by `maxTranslation` and `maxRotation`.
6. **Update bounds and sleep.** AABBs are recomputed with `speculativeDistance` margin. Sleep islands are updated if `allowSleep` is on.
7. **Dispatch** events to `onContact`, if set.

**Continuous collision.** `SolverSettings.continuousCollision` is on by default. In step 5, a dynamic body whose step motion is longer than its core radius sweeps that core sphere (3D) or circle (2D) against the non-trigger shapes of static and kinematic bodies. A second pass then tests each dynamic pair once, along their relative motion, and scales both displacements by the same time of impact. Collision filters and joint collision disabling are respected. The core radius is half of the smallest AABB half-extent. Velocity is kept, so the contact solver stops the body on the next step. See `clampContinuous` and `clampDynamicPairs` in `World3D.swift` and `World2D.swift`.

### 2.2 Broadphase

`SweepAndPrune` sorts body intervals on the X axis. The array persists between steps and is re-sorted by insertion sort, so temporal coherence keeps the cost close to linear. It is rebuilt when bodies are created or destroyed. Candidate pairs then pass a Y test and per-shape bounds tests.

### 2.3 Narrowphase, 2D

| Pair | Method |
| --- | --- |
| Circle and circle | Analytic. |
| Polygon and circle | Nearest edge or vertex region, or the centre-inside case. |
| Capsule and circle | Closest point on the core segment. |
| Capsule and capsule | Near-parallel: two points. Otherwise closest points on the segments. |
| Polygon and polygon | Separating-axis test over both edge sets (maximum separation). The reference face is chosen with a small bias. The incident edge is clipped against the reference face's side planes, giving up to two points with feature identifiers. |
| Polygon and capsule | The capsule core is treated as a thin polygon with the radius added to the margin. **Approximate.** |

`Polygon2D(points:)` takes the convex hull of its input (monotone chain). It rejects hulls with fewer than 3 or more than 16 vertices. Feature identifiers let contacts keep their impulses while the same feature stays in contact.

### 2.4 Narrowphase, 3D

| Pair | Method |
| --- | --- |
| Sphere and sphere | Analytic. |
| Sphere and box | Closest point on the box. If the centre is inside, the least-penetration axis is used. |
| Box and box | Separating-axis test over 15 axes: 3 per box, and 9 edge cross products. Face axes are preferred. Face contacts are clipped against the reference face, keeping up to four points. An edge-edge contact gives one point. |
| Capsule and sphere; capsule and capsule | Closest points on the segments. Near-parallel capsules give up to two points. |
| Box and capsule | Sphere tests at both endpoints and at the closest segment point; up to two points. |
| Plane and sphere, capsule, box or convex hull | Per-point tests. A box contributes up to eight corners, reduced to four. A hull contributes its vertices. |
| Convex hull and sphere or capsule | Closest point on the hull. The normal points from shape A toward shape B. |
| Convex hull and box, or hull and hull | Face normals and edge-edge crosses. Face axes are preferred. A face contact is clipped against the reference face (up to four points). An edge-edge contact is one point. |
| Triangle mesh and sphere or capsule | BVH query, closest point on each triangle, up to four deepest points, averaged normal. |
| Triangle mesh and convex hull | BVH query, then the same face and edge-edge test as hull versus hull, up to four deepest points. |
| Triangle mesh and box | **Approximated** by an inscribed capsule along the box's longest axis. |
| Plane against plane or mesh; mesh against mesh or plane | **Not supported.** No contacts are produced. |

The mesh BVH splits at the median of the largest centroid extent, with leaves of up to four triangles. Out-of-range indices log an error and produce an empty mesh.

### 2.5 Solver

- **Speculative contacts.** A separated point within `speculativeDistance` has bias `-separation / dt`, so it can close its gap in one step without penetrating.
- **Penetration.** A penetrating point has bias `baumgarte / dt * max(0, -(separation + linearSlop))`. Correction happens inside the velocity sweeps. There is no separate position pass.
- **Restitution.** If the closing speed exceeds `restitutionThreshold`, the target normal velocity is `-restitution * vn`. The restitution of a contact is the maximum of its two materials.
- **Friction.** 2D has one tangent, clamped to `friction * normalImpulse`. 3D has two tangents, clamped to a circular cone. Friction is solved before the normal impulse in each sweep.
- **Joints.** Point constraints use a 2 by 2 matrix in 2D and 3 by 3 in 3D. Distance constraints are one-dimensional. Springs use soft-constraint coefficients from frequency and damping ratio.
- **Mass.** Dynamic bodies compute mass and inertia from their non-trigger shapes. A dynamic body with no mass gets mass 1. Static and kinematic bodies have zero inverse mass.
- **Rotation locks.** In 2D, `fixedRotation` zeroes the inverse inertia. In 3D, `angularFactor` scales the world inverse inertia per axis.

### 2.6 Sleep

With `allowSleep`, each dynamic body accumulates `sleepTime` while its speeds stay below the sleep thresholds. Dynamic bodies linked by touching non-trigger contacts or by joints form islands (union-find). An island sleeps when every body has rested for `timeToSleep`. Sleeping bodies have their velocities zeroed and are skipped by integration. A contact that begins with a sleeping body wakes it. Creating a joint wakes both bodies. Most mutators wake a body, except `setDamping`.

## 3. Solver settings

`SolverSettings` is shared by both worlds and is `Codable`. Each world exposes it as `settings`.

| Field | Default | Meaning |
| --- | --- | --- |
| `velocityIterations` | `8` | Sweeps per step (at least 1 is used). |
| `positionIterations` | `3` | **Declared but not read** by either world. |
| `baumgarte` | `0.2` | Fraction of penetration corrected per step. |
| `linearSlop` | `0.005` | Penetration allowed before correction starts. |
| `restitutionThreshold` | `1` | Closing speed below which restitution is ignored. |
| `speculativeDistance` | `0.02` | Contact creation distance; also inflates bounds. |
| `warmStarting` | `true` | Re-applies the previous impulses. |
| `allowSleep` | `true` | Enables sleep islands. |
| `sleepLinearThreshold` | `0.05` | Linear speed below which a body is resting. |
| `sleepAngularThreshold` | `0.05` | Angular speed below which a body is resting. |
| `timeToSleep` | `0.5` | Seconds an island must rest before sleeping. |
| `maxTranslation` | `4` | Per-step translation cap, in world units. |
| `maxRotation` | `0.5 * .pi` | Per-step rotation cap, in radians. |

## 4. Materials and collision filtering

`PhysicsMaterial` defaults to `friction` 0.6, `restitution` 0 and `density` 1. Contacts mix friction by geometric mean, `sqrt(a * b)`, and restitution by maximum. Density is used only for mass.

`CollisionFilter` has `category` (default 1), `mask` (default all bits) and `group` (default 0). Shapes collide when:

- they share a non-zero `group`: a positive group always collides, and a negative group never does; otherwise
- `(a.category & b.mask) != 0` and `(b.category & a.mask) != 0`.

```swift
import FeroxPhysics

let player = CollisionFilter(category: 0b01, mask: 0b10)
let enemy = CollisionFilter(category: 0b10, mask: 0b01)
print(player.shouldCollide(with: enemy))            // true

// Ragdoll limbs of one character never collide with each other.
let limb = CollisionFilter(category: 0b100, mask: .max, group: -1)

// One bit for the layer, and a mask of layers to hit.
let fromLayer = CollisionFilter.layers(3, collidesWith: LayerMaskBits(rawValue: 0b1011))
```

Queries take the same `CollisionFilter`.

## 5. Bodies

`BodyType` has three cases: `.static` (never moves, infinite mass), `.dynamic` (driven by forces, gravity and contacts), and `.kinematic` (moved by velocity or transform, pushes dynamic bodies, ignores gravity and forces).

Bodies are created from `BodyDesc2D(type:position:angle:shapes:)` or `BodyDesc3D(type:position:rotation:shapes:)`, and both descriptions have the damping, gravity, sleep, `userData` and velocity fields. `createBody` returns a `BodyID`. `isValid(_:)` returns `false` once the body is destroyed, even if the slot is reused. `body(_:)` returns a read-only `Body2D` or `Body3D`, with `position`, `linearVelocity`, `isAwake`, `mass` and `userData`, and `interpolated(_:)` for render blending.

| Purpose | 2D and 3D call |
| --- | --- |
| Pose | `setTransform(_:position:angle:resetInterpolation:)` (3D: `rotation:`) |
| Velocity | `setLinearVelocity(_:_:)`, `setAngularVelocity(_:_:)` |
| Forces | `applyForce(_:_:at:)`, `applyTorque(_:_:)` |
| Impulses | 2D `applyLinearImpulse(_:_:at:)`; 3D `applyImpulse(_:_:at:)`. Both have `applyAngularImpulse`. |
| Type, shapes | `setType(_:_:)`, `setShapes(_:_:)` |
| Rotation lock | 2D `setFixedRotation(_:_:)`; 3D `setAngularFactor(_:_:)` |
| Damping, gravity | `setDamping(_:linear:angular:)`, `setGravityScale(_:_:)` |

Forces and torques are cleared after each step, so a continuous force must be reapplied every fixed step. Impulses change velocity at once. `setShapes` drops that body's contacts **without** ended events.

## 6. Shapes

2D: `Shape2D.circle(radius:center:)`, `Shape2D.box(halfExtents:center:angle:)` and `Shape2D.capsule(height:radius:)`. A custom outline is `Shape2D(.polygon(polygon))`, where `polygon` comes from `Polygon2D(points:)`.

3D: `Shape3D.sphere(_:)`, `Shape3D.box(_:)`, `Shape3D.capsule(height:radius:)` (aligned to local Y), `Shape3D.plane(normal:distance:)` (static bodies only), and `.mesh(TriangleMesh)` (static only). `TriangleMesh(vertices:indices:)` builds the BVH.

Every shape has `material`, `filter` and `isTrigger`. Triggers do not contribute mass or impulses, but they produce begin and end events and overlap results. Contact keys are a `(body, shape)` pair, so a compound or a tilemap may have more than 256 shapes on one body. The tilemap generator emits one box per solid run and does not stop at 255.

## 7. Joints

Joints are created with `createJoint(_:)`, which returns `nil` if either body is invalid. A `JointID` carries a generation. Destroying a body destroys its joints.

2D `JointDesc2D`:

| Case | Constraint | Options | Connected bodies collide |
| --- | --- | --- | --- |
| `.revolute(a:b:anchor:motor:limits:)` | Anchors coincide. | Motor. Angle limits. | No |
| `.distance(a:b:anchorA:anchorB:length:frequency:dampingRatio:minLength:maxLength:)` | Anchors stay at a length. | Spring if `frequency > 0`. Range with `minLength` and `maxLength`. Rigid if they are equal. | Yes |
| `.target(body:anchor:target:maxForce:frequency:dampingRatio:)` | Pulls a point towards a world target. | `maxForce`, frequency (at least 0.1 Hz). | Yes |

`setJointTarget(_:_:)` and `setMotorSpeed(_:_:)` change a joint afterwards. Nothing else can.

3D `JointDesc3D`:

| Case | Constraint | Options | Connected bodies collide |
| --- | --- | --- | --- |
| `.ball(a:b:anchor:)` | Anchors coincide. | None. | No |
| `.hinge(a:b:anchor:axis:motor:)` | Anchors coincide, axes aligned. | Motor only. **No angle limits.** | No |
| `.fixed(a:b:)` | Anchors coincide, rotation locked. | None. | No |
| `.distance(a:b:anchorA:anchorB:minLength:maxLength:)` | Length, or a range. | **No spring.** | Yes |

## 8. Queries

Ray and sweep queries skip triggers unless `includeTriggers` is set. Overlap queries differ, as noted.

| 2D method | Result and notes |
| --- | --- |
| `raycast(from:to:filter:includeTriggers:)` | Closest `RaycastHit2D?` on a segment. `fraction` is along it. |
| `raycastAll(from:to:filter:includeTriggers:radius:_:)` | Visits hits. Return `false` to stop. `radius` inflates shapes. |
| `circleCast(from:to:radius:filter:)` | Closest hit of a moving circle. Intended to be exact for convex polygons. Validate before relying on it. |
| `overlapPoint(_:filter:)`, `overlapCircle(center:radius:filter:)` | Shape tests. Triggers are included. |
| `overlapAABB(min:max:)` | **Bounds test only**, with margin, and no filter. |
| `contacts(of:)`, `activeContactCount` | Touching contacts, including trigger contacts. |

| 3D method | Result and notes |
| --- | --- |
| `raycast(origin:direction:maxDistance:filter:includeTriggers:)` | Closest `RaycastHit3D?`. `distance` is along the ray. |
| `raycastAll(origin:direction:maxDistance:filter:includeTriggers:radius:_:)` | Visits hits. |
| `sphereCast(origin:direction:radius:maxDistance:filter:)` | Closest hit of a moving sphere. See the table below. |
| `overlapSphere(center:radius:filter:includeTriggers:)` | Shape test. Triggers included by default. |
| `overlapBox(center:halfExtents:rotation:filter:)` | Shape test. No trigger parameter, so triggers are tested. |
| `contacts(of:)`, `activeContactCount` | Touching non-trigger contacts. |

Sphere casts are exact against spheres, capsules and planes, where the sweep equals inflating the shape by the radius. Against other shapes they approximate:

| Shape | Behaviour |
| --- | --- |
| Box | The box is inflated by the radius and the ray is cast against it. Conservative: hits at corners can be reported early. |
| Triangle mesh | The ray is cast, and the hit distance is reduced by the radius. Exact for a head-on hit on a flat face. Approximate at edges and corners, and not guaranteed conservative there. |

## 9. Contact events

`ContactEvent<V>` has `phase` (`.began` or `.ended`), `bodyA`, `bodyB`, `shapeA`, `shapeB`, `userDataA`, `userDataB`, `isTrigger`, `points` (empty for ended and trigger events), `normal` (A to B) and `normalImpulse` (sum for the step).

Begin is emitted when a contact first touches. Ended is emitted when a touching contact stops, when its bodies stop overlapping, and when a body is destroyed. Events are kept in `contactEvents` until the next step, and are passed to `onContact` after the step.

**ECS events.** `PhysicsSystem2D` and `PhysicsSystem3D` convert each event into `CollisionEvent2D` or `CollisionEvent3D`, with entities recovered from `userData`, and call `context.events.enqueue(_:)`. Each carries `phase`, `entityA`, `entityB`, `isTrigger`, `points`, `normal`, `impulse`, `involves(_:)` and `other(than:)`.

Enqueued events reach subscribers only when the `EventBus` is flushed. `Engine` flushes the bus after every fixed step and again before rendering (`Sources/Ferox/Engine.swift`), so subscribers see a fixed-step event in the same frame.

## 10. ECS integration

| Component | Role |
| --- | --- |
| `RigidBody2D` / `RigidBody3D` | Simulated body. Fields include `type`, damping, `gravityScale`, `fixedRotation` or `angularFactor`, `allowSleep`, `interpolate` and `initialVelocity`. |
| `Collider2D` / `Collider3D` | Shapes. Builders include `Collider2D.box(_:)`, `Collider2D.circle(_:)`, `Collider3D.box(_:)`, `Collider3D.sphere(_:)` and `Collider3D.capsule(height:radius:)`. 3D shapes are `ColliderShape3D`. |
| `Joint2D` / `Joint3D` | Joint to `connected`, with local anchors. Kinds mirror the descriptions in [section 7](#7-joints), but 2D supports only revolute and distance, and 3D supports ball, hinge, fixed and distance. |
| `TilemapCollider` | Static boxes from `Tilemap.solidTiles`, merged by row. Rebuilt when `Tilemap.revision` changes. |
| `PhysicsBody2DHandle`, `PhysicsBody3DHandle` | Runtime link to the `BodyID`. Not serialised. |

A `RigidBody` without a `Collider` has mass and no shapes. A `Collider` without a `RigidBody` is static. `registerPhysicsComponents()` on `ComponentRegistry` registers the seven serialisable physics components. Nothing calls it by default.

### The systems

`PhysicsSystem2D(physics:)` and `PhysicsSystem3D(physics:)` run in `fixedUpdate`, with `order` 0 and 1 respectively. On `attach`, each stores its world as a resource, so `world.resource(PhysicsWorld2D.self)` finds it.

Each `update`:

1. **`sync`**
   - Destroys bodies whose entity is dead or has lost its physics components, and destroys joints whose component is gone.
   - Creates a body for each new physics entity that has a `Transform` and is active in its hierarchy. The pose comes from the world transform.
   - Rebuilds tilemap shapes when the revision changes (2D only).
   - Teleports a body whose entity's pose differs from the last synchronised pose.
   - Creates each joint once both bodies exist, retrying every step.
2. **`step(context.dt)`**.
3. **`writeBack`**: writes each non-static body's pose into `Transform`, converting to local space under a parent.
4. **Events** are enqueued on `context.events`.

`interpolate(_:alpha:)` writes blended poses for awake bodies whose `RigidBody` has `interpolate` set. `Engine` calls it once per frame after the fixed steps, with `FrameTime.interpolationAlpha`.

Bodies are created once. Later changes to a collider or a `RigidBody.type` are ignored by the bridge. Use the body API instead:

```swift
if let id = physicsSystem.body(for: crate) {
    physicsSystem.physics.setShapes(id, [Shape2D.box(halfExtents: Vec2(0.25, 0.5))])
    physicsSystem.physics.setType(id, .kinematic)
}
```

In 3D, sphere and capsule radii scale by the average of the entity's scale, box extents scale per axis, and mesh shapes are resolved through `PhysicsSystem3D.meshProvider`. An unresolved mesh is skipped with a warning.

## 11. Character controller

`CharacterController3D` is a capsule-based kinematic controller. It is a component, needs no rigid body, and moves the entity's `Transform` directly. Each `move(_:displacement:dt:physics:jump:)` call adds gravity, casts spheres from the capsule's base and top along the motion, slides along surfaces for up to four iterations, and probes for ground. It returns the motion actually applied. Surfaces within `maxSlopeDegrees` (default 50) of up count as ground. Other defaults are `radius` 0.35, `height` 1.8, `skinWidth` 0.02 and `gravity` -20. `isGrounded` and `verticalVelocity` are readable only.

## 12. Debug visualisation

`debugLines(includeContacts:includeAABBs:)` (2D) and `debugLines(includeContacts:)` (3D) return `DebugLine` values with two endpoints and a `kind`: `collider`, `sleeping`, `staticCollider`, `trigger`, `contact`, `contactNormal`, `joint`, `aabb` or `force`. The `force` kind is declared but **never emitted**. Circles use 24 segments in 2D and 20 in 3D. 3D meshes are drawn up to 20,000 triangles per shape.

## 13. Code examples

### A 2D world without the ECS

```swift
import FeroxMath
import FeroxPhysics

let physics = PhysicsWorld2D(gravity: Vec2(0, -9.81))
physics.createBody(BodyDesc2D(type: .static, position: Vec2(0, -1),
                              shapes: [Shape2D.box(halfExtents: Vec2(10, 0.5))]))
let ball = physics.createBody(BodyDesc2D(type: .dynamic, position: Vec2(0, 5),
                                         shapes: [Shape2D.circle(radius: 0.5)]))

for _ in 0..<120 {
    physics.step(1.0 / 60.0)
}
if let body = physics.body(ball) {
    print("ball at", body.position, "asleep:", !body.isAwake)
}
```

### A 3D impulse and a raycast

```swift
let physics3D = PhysicsWorld3D(gravity: Vec3(0, -9.81, 0))
physics3D.createBody(BodyDesc3D(type: .static, position: Vec3(0, -1, 0),
                                shapes: [Shape3D.box(Vec3(20, 0.5, 20))]))
let crate = physics3D.createBody(BodyDesc3D(type: .dynamic, position: Vec3(0, 3, 0),
                                            shapes: [Shape3D.box(Vec3(0.5, 0.5, 0.5))]))

// Applied above the centre, so the crate also spins.
physics3D.applyImpulse(crate, Vec3(2, 0, 0), at: Vec3(0, 3.5, 0))
physics3D.step(1.0 / 60.0)

if let hit = physics3D.raycast(origin: Vec3(0, 10, 0), direction: Vec3(0, -1, 0), maxDistance: 50) {
    print("surface at distance", hit.distance)
}
```

### An ECS body with events

```swift
import FeroxCore
import FeroxMath
import FeroxPhysics
import FeroxScene

ComponentRegistry.shared.registerPhysicsComponents()

let world = World()
let physicsSystem = PhysicsSystem2D()
let scheduler = SystemScheduler(world: world)
scheduler.add(physicsSystem)

let ground = world.createEntity(named: "Ground", transform: Transform(position: Vec3(0, -1, 0)))
world.add(Collider2D.box(Vec2(20, 1)), to: ground)

let crate = world.createEntity(named: "Crate", transform: Transform(position: Vec3(0, 4, 0)))
world.add(RigidBody2D(type: .dynamic), to: crate)
world.add(Collider2D.box(Vec2(1, 1)), to: crate)

let events = EventBus()   // in the engine, subscribe on the bus the systems enqueue to
events.subscribe(CollisionEvent2D.self) { ev in
    guard ev.phase == .began, !ev.isTrigger, ev.involves(crate) else { return }
    print("crate hit", ev.other(than: crate), "impulse", ev.impulse)
}
```

### A revolute motor and a hinge

```swift
let hub = world.createEntity(named: "Hub", transform: Transform(position: Vec3(2, 0, 0)))
world.add(RigidBody2D(type: .dynamic), to: hub)
world.add(Collider2D.circle(0.4), to: hub)

let arm = world.createEntity(named: "Arm")
world.add(RigidBody2D(type: .static), to: arm)
world.add(Collider2D.box(Vec2(2, 0.1)), to: arm)

// The hub spins at 4 rad/s, with at most 10 N·m of torque.
world.add(
    Joint2D(.revolute(motorSpeed: 4, maxMotorTorque: 10, lowerAngle: nil, upperAngle: nil),
            connected: arm, localAnchor: Vec2(0, 0), connectedLocalAnchor: Vec2(2, 0)),
    to: hub)

let frame = world.createEntity(named: "Frame")
world.add(RigidBody3D(type: .static), to: frame)
world.add(Collider3D.box(Vec3(0.1, 2, 1)), to: frame)

let door = world.createEntity(named: "Door", transform: Transform(position: Vec3(0.5, 1, 0)))
world.add(RigidBody3D(type: .dynamic), to: door)
world.add(Collider3D.box(Vec3(1, 2, 0.1)), to: door)
world.add(
    Joint3D(.hinge(axis: Vec3(0, 1, 0), motorSpeed: nil, maxMotorTorque: 0),
            connected: frame, localAnchor: Vec3(-0.5, 0, 0)),
    to: door)
```

The joints are created on the first step where both bodies exist. The hinge has no angle limits.

### A character controller step

```swift
let player = world.createEntity(named: "Player", transform: Transform(position: Vec3(0, 2, 0)))
world.add(CharacterController3D(), to: player)

func movePlayer(_ player: Entity, input: Vec2, jumpPressed: Bool, dt: Float) {
    guard var cc = world.get(CharacterController3D.self, player),
          var transform = world.get(Transform.self, player) else { return }
    let displacement = Vec3(input.x, 0, input.y) * 5
    cc.move(&transform, displacement: displacement, dt: dt, physics: physics3D,
            jump: jumpPressed && cc.isGrounded ? 7 : nil)
    world.set(transform, for: player)
    world.set(cc, for: player)
}
```

## 14. Limitations

- **Limitation: continuous collision is a core sweep.** Dynamic bodies are swept against static and kinematic shapes, then each dynamic pair is scaled once along the relative motion. The sweep uses a core sphere or circle, so a thin feature can still be missed. Sphere sweeps against boxes and meshes are conservative approximations. `maxTranslation` limits explosions but is not a substitute.
- **Limitation: hull inertia is the AABB.** `ConvexHull3D.build` returns nil for coplanar or collinear points. Sphere and capsule contacts use the closest point. Hull versus box, hull versus hull, and hull versus triangle mesh use face axes and edge-edge axes, with a clipped face manifold (one point on an edge-edge axis). Inertia is taken from the hull's AABB about its centroid.
- **Limitation: 2D polygons are convex, with at most 16 vertices.** Split concave outlines.
- **Limitation: box against mesh is approximated.** Mesh against plane, mesh against mesh and plane against plane produce no contacts.
- **Limitation: sphere casts against boxes and meshes are approximations** (see [section 8](#8-queries)).
- **Limitation: no gyroscopic term.**
- **Limitation: single-threaded.** The step does not use `Jobs`.
- **Limitation: tilemaps are one body.** A large tilemap is a single static body with one box per solid run. That is correct, and it can be a lot of shapes.
- **Limitation: `positionIterations` is unused.**
- **Limitation: no hinge limits, and no spring on 3D distance joints.**
- **Limitation: the ECS bridge does not update bodies after creation.** Use the body API (see [section 10](#10-ecs-integration)).
- **Limitation: `setShapes` drops contacts without ended events.**
- **Limitation: forces are per step.**
- **Limitation: event delivery and interpolation depend on the engine,** which is not in this snapshot.
- **Limitation: joint definitions are fixed at creation,** apart from the motor speed and target setters.

## 15. Validation status

- `Tests/FeroxPhysicsTests` covers free fall, resting contacts, restitution, triggers, raycasts, filtering, sleeping, teleporting, contact events, the ECS bridge, continuous collision (`ContinuousCollisionTests.swift`), dynamic-versus-dynamic sweeps and convex hulls (`ConvexAndDynamicCCDTests.swift`), and determinism (`PhysicsDeterminismTests.swift`). Hull tests cover sphere, capsule, box, hull-hull face manifolds, edge-edge separation, and mesh-hull contacts.
- The physics target is 58 XCTest cases. They pass on Swift 6.2.3 (Linux) and previously passed on an M1 Max with macOS 27 and Swift 6.4.
- Contact keys are sorted before the solve, so results are repeatable from run to run. `PhysicsDeterminismTests.swift` checks this.
- The behaviour in this document was derived from the source and checked against those tests.
- No benchmark numbers are given. Performance should be measured, as described in [21-Performance.md](21-Performance.md).

## 16. Related documents

- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): fixed-step timing, interpolation and system order.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): entities, components and the scheduler.
- [14-Input.md](14-Input.md): input read before the physics step, and latching for fixed updates.
- [15-User-Interface.md](15-User-Interface.md): physics-driven interface elements.
- [18-Assets.md](18-Assets.md): mesh assets used by `ColliderShape3D.Geometry.mesh`.
- [20-Gameplay-API.md](20-Gameplay-API.md): collision handling in gameplay code.
- [21-Performance.md](21-Performance.md): measuring the physics step.
- [29-API-Reference.md](29-API-Reference.md): the complete API listing.
