# Scene and Entities

The scene layer (module `FeroxScene`) provides Ferox's entity-component-system (ECS) world, a parent-child hierarchy with transform propagation, a phase-ordered system scheduler, a JSON format for scenes and prefabs, and a `SceneManager` that loads, unloads and fades between scenes. Entities are generational handles. Their data lives in one sparse-set store per component type, as value-type components. Behaviour lives in systems. This document describes the implementation in `Sources/FeroxScene`, the rules for iterating and mutating a `World`, and the serialisation rules that decide what survives a save and load.

Physics, rendering and input attach to the scene through components and resources. See [13-Physics.md](13-Physics.md), [08-Rendering-3D.md](08-Rendering-3D.md) and [14-Input.md](14-Input.md). Frame phases are described in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md).

## Contents

1. [Design and source files](#1-design-and-source-files)
2. [Entities](#2-entities)
3. [The sparse-set component store](#3-the-sparse-set-component-store)
4. [Creating and destroying entities](#4-creating-and-destroying-entities)
5. [Components](#5-components)
6. [Reading and writing components](#6-reading-and-writing-components)
7. [Queries](#7-queries)
8. [Deferred structural changes](#8-deferred-structural-changes)
9. [Resources](#9-resources)
10. [Hierarchy](#10-hierarchy)
11. [Transforms and TransformSystem](#11-transforms-and-transformsystem)
12. [Tags, layers, groups and names](#12-tags-layers-groups-and-names)
13. [Render components](#13-render-components)
14. [Systems and scheduling](#14-systems-and-scheduling)
15. [Serialisation](#15-serialisation)
16. [Prefabs](#16-prefabs)
17. [Scene management](#17-scene-management)
18. [Performance, ownership and threading](#18-performance-ownership-and-threading)
19. [Limitations](#19-limitations)
20. [Related documents](#20-related-documents)

## 1. Design and source files

- An **entity** is an `Entity` value (slot index plus generation). It carries no data.
- A **component** is a value type. Each component type has one `ComponentStorage<T>`, a sparse set.
- A **World** owns the entity slots, the storages and a map of singleton **resources**.
- A **system** runs in a fixed phase order and reads or writes the world. Behaviour belongs in systems.
- The **hierarchy** is the internal `Parent` and `Children` components, managed only through `World.setParent`.
- A **scene** is a JSON document of entity records, whose components are named by a stable serialised name.

| File | Responsibility |
| --- | --- |
| `World.swift` | Entity slots, storage registry, queries, deferred operations, resources. |
| `ComponentStorage.swift` | Sparse-set store for one component type. |
| `Entity.swift` | `Entity`, `EntityRemapTable`, and `Codable` for entity references. |
| `CoreComponents.swift` | `Name`, `Transform`, `WorldTransform`, `Parent`, `Children`, `Disabled`, `Tags`, `LayerMask`, `Layer`, `Groups`, `PersistentID`, `SceneMember`, `PersistAcrossScenes`. |
| `Hierarchy.swift` | Parenting, traversal, world matrices, name, tag and group lookup. |
| `TransformSystem.swift` | Propagation of `Transform` into `WorldTransform`. |
| `Systems.swift` | `SystemPhase`, `SystemContext`, `System`, `ClosureSystem`, `SystemScheduler`. |
| `Serialization.swift` | `SerializableComponent`, `ComponentRegistry`, `SceneDocument`, `SceneSerializer`, `UnknownComponents`. |
| `SceneManager.swift` | `Prefab`, `PrefabInstance`, `SceneManager`, `SceneTransition`. |
| `RenderComponents.swift` | Render-facing component data. |

## 2. Entities

`Entity` has two `UInt32` fields, `index` and `generation`. It is `Hashable`, `Sendable`, `Comparable` (by index, then generation) and `Codable`. `Entity.null` has index `UInt32.max`.

`world.isAlive(_:)` is the reliable liveness check. Destroying an entity increments its slot's generation, so a handle that outlives its entity becomes stale. Lookups with a stale handle fail, rather than reaching whatever entity reuses the slot.

```swift
import FeroxScene

let world = World()
let enemy = world.createEntity(named: "Enemy")
world.destroy(enemy)

let pickup = world.createEntity(named: "Pickup")
// Free slots are reused last-in, first-out, so the index is often the same.
print(pickup.index == enemy.index)         // true, typically
print(world.isAlive(enemy))                // false
print(world.get(Name.self, enemy) == nil)  // true: the generation differs
```

Store `Entity` values freely, but check `isAlive` after anything that may have destroyed the entity, such as a physics callback or a deferred destroy.

## 3. The sparse-set component store

`ComponentStorage<T>` keeps three parallel structures: `dense` (the values, contiguous), `entities` (the owner of each dense slot), and `sparse` (indexed by entity index, holding the dense slot or `-1`). Insertion appends. Removal swaps the last element into the hole, updates the moved element's sparse entry, and pops.

| Operation | Cost | Notes |
| --- | --- | --- |
| Add (new) | O(1) amortised | Sparse array grows by doubling, minimum 64. |
| Replace | O(1) | No `structureVersion` change. |
| Remove | O(1) | Swap with last, then pop. |
| `has` / `get` | O(1) | Verifies the full handle, including generation. |
| Iterate | O(n) | Dense order. |
| `entities(with:)` | O(n) | Returns a copied array. |

Consequences:

- **Iteration order is not stable.** Removal changes it. Do not depend on query order, and do not store dense indices across frames.
- **The sparse array is sized by the highest live entity index.** Indices are recycled, so this is bounded by peak population, not by the total ever created.
- **Adding a component an entity already has replaces the value.** It is not an error.

## 4. Creating and destroying entities

```swift
let raw = world.createEntity()
let crate = world.createEntity(
    named: "Crate",                                  // adds a Name
    transform: Transform(position: Vec3(2, 0, 0)),   // adds a Transform
    parent: raw)                                     // calls setParent when not .null
```

`destroy(_:)` is recursive. It destroys children first (from a copy of the child list), detaches from the parent, calls `onEntityDestroyed`, removes every component, increments the slot generation, and returns the slot to the free list. Destroying a dead entity does nothing. Creates and destroys bump `World.structureVersion`, which caches can compare.

`World.clear()` removes all entities and components, keeps resources, and does **not** call `onEntityDestroyed`.

## 5. Components

A component conforms to `Component`, an empty marker protocol. Make components value types, because queries copy values in and out of storage.

```swift
struct Health: Component {
    var current: Float
    var maximum: Float
}

struct Velocity: Component {            // runtime only: not saved
    var value: Vec3
}
```

A component that is saved in scenes and prefabs, and edited in the inspector, conforms to `SerializableComponent`. That protocol requires `Codable` and provides `static var serializedName`, which defaults to the type name. Override it to rename a type without breaking old scenes.

```swift
struct Spawner: SerializableComponent {
    static var serializedName: String { "Spawner" }
    var interval: Float
    var prefabID: String
}
```

Built-in serialisable types are `Name`, `Transform`, `Disabled`, `Tags`, `Layer`, `Groups`, `PersistentID`, `PersistAcrossScenes`, the render components in [section 13](#13-render-components), and `PrefabInstance`. `Parent`, `Children`, `WorldTransform`, `SceneMember` and the physics runtime handles are **not** serialised. The hierarchy is saved through each record's `parent` field.

## 6. Reading and writing components

| Call | Behaviour | Structural |
| --- | --- | --- |
| `add(_:to:)` | Inserts, or replaces the value. | If new. |
| `remove(_:from:)` | Removes if present. | Yes. |
| `has(_:_:)`, `get(_:_:)` | Presence test; copy of the value or `nil`. | No. |
| `set(_:for:)` | Overwrites an existing value. Returns `false` if absent. | No. |
| `modify(_:_:_:)` | Mutates through `inout`. Returns `nil` if absent. | No. |
| `world[T.self, e]` | Get, or add (non-nil) and remove (nil). | Depends. |
| `count(of:)`, `components(of:)` | Counts and type-erased values. | No. |

```swift
let player = world.createEntity(named: "Player")
world.add(Health(current: 100, maximum: 100), to: player)
world.modify(Health.self, player) { $0.current -= 15 }
world.set(Health(current: 50, maximum: 100), for: player)
```

`set` writes the whole value, including any stored `isDirty` flag. Prefer `modify` when only some fields change.

## 7. Queries

| Call | Components | Notes |
| --- | --- | --- |
| `forEach(A.self) { e, a in }` | One | `a` is `inout` and is written back. |
| `forEach(A.self, B.self) { e, a, b in }` | Two | Driven by the smaller store. Types must differ. |
| `forEach(A.self, B.self, C.self) { e, a, b, c in }` | Three | Driven by the smallest store. Types must differ. |
| `read(A.self) { e, a in }` | One | Read-only; no write-back. |
| `withDenseStorage(A.self) { ents, comps in }` | One | Raw buffers; `nil` if the store is absent. |

`forEach` copies each value out, passes it as `inout`, and writes it back, even when unchanged. Use `read` when you do not mutate.

```swift
world.forEach(Transform.self, Velocity.self) { _, transform, velocity in
    transform.translate(velocity.value * dt)
}

var living = 0
world.read(Health.self) { _, health in
    if health.current > 0 { living += 1 }
}
```

**Copy-in, copy-out caveat.** Inside `forEach`, the `inout` value is authoritative for the current entity. Calling `world.set(_:for:)` on the same type for that entity is overwritten by the write-back. Mutate the `inout` parameter instead. Writes to other entities, or other types, are safe.

### Parallel work with `withDenseStorage`

Element `i` of the component buffer belongs to `entities[i]`. Structural changes are deferred while the closure runs. Split the range with `Jobs.parallelFor`, so each worker writes only its own indices.

```swift
import FeroxCore

_ = world.withDenseStorage(Transform.self) { _, transforms in
    Jobs.parallelFor(count: transforms.count, minChunk: 2048) { range in
        for i in range {
            transforms[i].translate(Vec3(0, 0.001, 0))
        }
    }
}
```

`Jobs.parallelFor` takes an `@Sendable` closure. Workers may read buffers they were given and write their own indices. They must not call `add`, `remove`, `destroy`, `setParent`, or `denseIndex`. `TransformSystem` builds the flat-root index list on the calling thread, then hands each worker a disjoint range of that list and of the dense transform buffers.

## 8. Deferred structural changes

Each query increments an iteration counter on entry and decrements it on exit. While the counter is above zero, `destroy`, `add`, `remove` and anything passed to `deferStructural(_:)` are queued. The queue is replayed in order when the outermost query returns. `SystemScheduler.run` also calls `flushDeferred()` after each system.

- `createEntity()` is **not** deferred, so the entity exists at once. Its `Name` and `Transform`, added by `createEntity(named:transform:parent:)`, are deferred. `setParent` is partly immediate. Avoid it during iteration.
- A destroyed entity stays alive, and its components stay readable, until the query returns.
- An addition queued in a query is not visible to that query.
- `get`, `has`, `set`, `modify` and the read-only queries are never deferred.
- `isIterating` reports whether deferral is active.

```swift
world.forEach(Health.self) { e, health in
    if health.current <= 0 { world.destroy(e) }   // queued until the query returns
}

world.forEach(Health.self) { e, health in
    guard health.current <= 0, let position = world.get(Transform.self, e)?.position else { return }
    world.deferStructural {
        world.createEntity(named: "Explosion", transform: Transform(position: position))
    }
}
```

`deferStructural(_:)` runs at once when no iteration is active.

## 9. Resources

Resources are singletons keyed by type, for state that is not attached to an entity. They survive `World.clear()`. `PhysicsSystem2D` and `PhysicsSystem3D` store their physics worlds as resources when attached.

```swift
struct GameClock { var elapsed: Double = 0 }

world.setResource(GameClock())
if var clock = world.resource(GameClock.self) {
    clock.elapsed += dt
    world.setResource(clock)
}
world.removeResource(GameClock.self)
```

## 10. Hierarchy

```swift
@discardableResult
func setParent(_ child: Entity, _ parent: Entity, keepWorldTransform: Bool = false) -> Bool
```

- Returns `false` if either entity is dead, if the child equals the parent, or if the change would create a **cycle**. Cycle detection walks up from `parent`.
- `.null` makes the child a root, without changing its local transform.
- With `keepWorldTransform: true`, the world matrix is captured first, and the local transform is recomputed against the new parent. Use this for editor drag-and-drop.

| Call | Result |
| --- | --- |
| `parent(of:)`, `children(of:)` | Live parent, and ordered child list. |
| `visitSubtree(_:depth:_:)` | Depth-first visit. |
| `rootEntities` | Entities with a `Transform` and no parent, sorted by `Entity` order. |
| `worldMatrix(of:)` | Walks ancestors, using `Transform` values directly. |
| `setWorldPosition(_:_:)` | Sets a world position by adjusting the local position. |
| `isActiveInHierarchy(_:)` | `false` if the entity or an ancestor has `Disabled`. |

```swift
let root = world.createEntity(named: "Vehicle")
let wheel = world.createEntity(named: "Wheel", transform: Transform(position: Vec3(1, 0, 0)))
world.setParent(wheel, root, keepWorldTransform: true)

print(world.setParent(root, wheel))        // false: would create a cycle
world.add(Disabled(), to: root)
print(world.isActiveInHierarchy(wheel))    // false
```

`Disabled` is a marker. Its source comment says it skips an entity in gameplay, physics and rendering, and that rendering applies it to the whole subtree. In this repository the physics bridge checks `isActiveInHierarchy` only when it creates a body, so disabling does not remove an existing body. See [13-Physics.md](13-Physics.md).

`worldMatrix(of:)` walks at most 1024 ancestors and stops silently beyond that. Use `WorldTransform` in systems.

## 11. Transforms and TransformSystem

`Transform` stores a local position, rotation and scale. Its observers set `isDirty` on **any** write, including writes of an equal value. The flag is not a value comparison.

`WorldTransform` holds the cached `matrix`, `previous` (last frame's matrix, for motion vectors) and `resetHistory`.

`TransformSystem.update(_:)` runs once per rendered frame, after gameplay and physics:

1. Every `Transform` without a `WorldTransform` gets one.
2. **Flat roots** (no parent, no children) are listed on the calling thread. `Jobs.parallelFor` then updates disjoint ranges of the dense arrays, with a minimum chunk of 2048. Workers do not read the component stores.
3. **Hierarchy roots** are walked depth-first. A subtree is recomputed only if an ancestor or the entity itself is dirty.

In each pass, `previous` is set to the old `matrix` first. A second call in the same frame therefore makes `previous` equal to `matrix`, and motion vectors become zero.

```swift
world.modify(Transform.self, player) { $0.position = spawnPoint }
TransformSystem.resetHistory(world, player)   // no motion blur from the old position
```

## 12. Tags, layers, groups and names

| Type | Purpose |
| --- | --- |
| `Name` | Label shown in the editor. `ExpressibleByStringLiteral`. |
| `Tags`, `Groups` | Sets of strings. |
| `Layer` | One layer index, clamped to 0...31. Its `mask` is one bit. |
| `LayerMask` | 32-bit option set. `.default` (bit 0), `.ui` (bit 5), `.editorOnly` (bit 31), `.all`. |
| `PersistentID` | Stable identifier, assigned on first save. |
| `SceneMember` | Owning scene, managed by `SceneManager`. |
| `PersistAcrossScenes` | Marks an entity to survive a scene unload. |

```swift
world.add(Tags(["Enemy"]), to: goblin)
world.add(Groups(["Wave1"]), to: goblin)
world.add(Layer(3), to: goblin)

let enemies = world.entities(tagged: "Enemy")
let hero = world.find(named: "Player")
```

`find(named:)` returns the first match in **dense storage order**, which is not guaranteed to be creation order. All three lookups are linear. Cache them if called each frame.

## 13. Render components

These are defined here so scenes can be authored and tested without Metal. Rendering behaviour is in [08-Rendering-3D.md](08-Rendering-3D.md).

| Component | Purpose |
| --- | --- |
| `Camera` | Projection, field of view, clear colour, viewport, culling mask, `priority`. |
| `Light` | Directional, point or spot light. `is2D` selects 2D lighting. |
| `MeshRenderer`, `MaterialOverrides`, `SkinnedMeshRenderer` | Mesh and material binding, with per-instance overrides and joint entities. |
| `LODGroup` | Level-of-detail selection by projected screen height. |
| `SpriteRenderer`, `ShapeRenderer`, `Parallax`, `Tilemap` | 2D drawing. `Tilemap` has `revision` and `solidTiles`, which physics reads. |
| `Environment`, `ReflectionProbe` | Sky, fog, image-based lighting, and local reflections. |

## 14. Systems and scheduling

`SystemPhase` cases run in this order: `earlyUpdate` (input mapping, network receive), `fixedUpdate` (simulation, 0 to N times a frame), `update` (variable-rate gameplay), `lateUpdate` (animation, camera follow, transform propagation), and `preRender` (render-data extraction).

The `System` protocol requires `phase` and `update(world:context:)`. It also has `order` (default 0), `runsInEditMode` (default `false`), `isEnabled` (default `true`), and optional `attach(world:)` and `detach(world:)`. `SystemContext` carries `time`, `dt`, `events` (an `EventBus`) and `isEditMode`.

```swift
final class Spinner: System {
    let phase: SystemPhase = .update
    let order = 10

    func update(world: World, context: SystemContext) {
        world.forEach(Transform.self, Spin.self) { _, transform, spin in
            transform.rotate(Quat(angle: spin.speed * context.dt, axis: Vec3(0, 1, 0)))
        }
    }
}

struct Spin: Component { var speed: Float }

let scheduler = SystemScheduler(world: world)
scheduler.add(Spinner())
scheduler.add(ClosureSystem("Cleanup", phase: .lateUpdate) { world, _ in
    world.forEach(Health.self) { e, h in if h.current <= 0 { world.destroy(e) } }
})
```

`SystemScheduler` holds the world weakly. It sorts stably by phase, then `order`, then insertion, on the first run after a change. For each system in a phase it checks `isEnabled` and, in edit mode, `runsInEditMode`. It runs each system in a `Profiler` scope named after its type, then calls `flushDeferred()`.

## 15. Serialisation

### 15.1 Document format

A `SceneDocument` is written as JSON (`.fxscene` or `.fxprefab`, per the source comment). It has `formatVersion` (currently 1), `name`, `entities` (records with a document-local `id`, an optional `parent` id, and `components` keyed by serialised name) and `metadata`. `jsonData(pretty:)` sorts keys. `Vec2` and `Vec3` are arrays, and `Quat` and `Color` are objects with named fields.

```json
{
  "entities" : [
    {
      "components" : {
        "Name" : { "value" : "Player" },
        "Tags" : { "values" : [ "Player" ] },
        "Transform" : { "position" : [ 0, 1, 0 ], "rotation" : { "x" : 0, "y" : 0, "z" : 0, "w" : 1 }, "scale" : [ 1, 1, 1 ] },
        "Health" : { "current" : 100, "maximum" : 100 }
      },
      "id" : 0
    },
    {
      "components" : {
        "Name" : { "value" : "Sword" },
        "Transform" : { "position" : [ 0.5, 0, 0 ], "rotation" : { "x" : 0, "y" : 0, "z" : 0, "w" : 1 }, "scale" : [ 1, 1, 1 ] }
      },
      "id" : 1,
      "parent" : 0
    }
  ],
  "formatVersion" : 1,
  "metadata" : {},
  "name" : "Level 1"
}
```

The example is illustrative. It shows the shape the encoder produces.

### 15.2 Validation

`SceneDocument.load(from:limits:)` checks the byte size, decodes, and calls `validate(limits:)`. `validate` rejects the following:

| Rule | Error |
| --- | --- |
| `formatVersion` outside 1...current | `unsupportedVersion` |
| More than 1,000,000 entities | `tooManyEntities` |
| Duplicate `id` | `duplicateID` |
| `parent` not in the document | `invalidParent` |
| Parent cycle, or component nesting deeper than `maxNestingDepth` (128) | `malformed` |
| File larger than `maxFileBytes` (512 MiB) | `malformed` |

`SceneSerializer.decode` validates again, with default limits.

### 15.3 Registry, custom components and unknown payloads

`ComponentRegistry.shared` is created on first access and registers the built-ins. Registration is lock-protected.

```swift
struct Health: SerializableComponent {
    var current: Float
    var maximum: Float
}

ComponentRegistry.shared.register(Health.self) { Health(current: 100, maximum: 100) }
ComponentRegistry.shared.registerPhysicsComponents()   // not called by default
```

`registerPhysicsComponents()` is defined in `FeroxPhysics`, and nothing in this repository calls it. A game must call it to save physics components.

Components whose names are not registered are dropped on encode, unless they are carried as `UnknownComponents`. With `SceneSerializer.strict == false` (the default), decoding keeps unknown payloads in `UnknownComponents`, logs a warning, and writes them back unchanged on save. With `strict == true`, decoding throws `SceneError.unknownComponent`.

### 15.4 Entity references

`Entity` is `Codable` through an `EntityRemapTable`. An entity inside the document is written as its local id, and one outside as `-1`. On decode, `-1` becomes `Entity.null`.

```swift
struct FollowTarget: SerializableComponent {
    var target: Entity   // saved as, for example: "FollowTarget" : { "target" : 1 }
}
```

References survive a round trip, although runtime indices differ. A reference to an entity outside the saved roots becomes `.null` on load.

### 15.5 Save and load

```swift
let doc = try SceneSerializer().encode(world: world, name: "Level 1")
try doc.jsonData(pretty: true).write(to: url, options: .atomic)

let loaded = try SceneDocument.load(from: Data(contentsOf: url))
let created = try SceneSerializer().decode(loaded, into: World())
print("Loaded \(created.count) entities")
```

`encode(world:name:roots:)` serialises the roots and their descendants, or every root when `roots` is `nil`. `decode` creates entities, adds components, then sets parents. If any step throws, the created entities are destroyed and the error is rethrown.

## 16. Prefabs

A `Prefab` is a reusable serialised subtree.

```swift
let prefab = try Prefab.capture(player, in: world, name: "Player")
let a = try prefab.instantiate(into: world, position: Vec3(0, 0, 0))
let b = try prefab.instantiate(into: world, position: Vec3(5, 0, 0))
```

`capture(_:in:id:name:)` serialises the root and its descendants. `instantiate(into:parent:position:rotation:)` decodes the document, adds a `PrefabInstance` holding the prefab's `AssetID`, and sets the root's `Transform`. When `parent` is given, the position is local to that parent. Instantiation does not add `SceneMember`. Call `SceneManager.adopt(_:)` to add an object to the active scene.

## 17. Scene management

`SceneManager` loads every scene into one shared `World`. Each entity created by a load gets a `SceneMember`, so physics, rendering and queries see all loaded scenes.

```swift
let scenes = SceneManager(world: world)
scenes.register("Menu", file: menuURL)
scenes.register("Level1", provider: {
    try SceneDocument.load(from: Data(contentsOf: level1URL))
})

try scenes.load("Menu")                         // single: unloads everything first
try scenes.load("Hud", mode: .additive)         // additive: keeps existing scenes
scenes.transition(to: "Level1", transition: SceneTransition(duration: 0.6))

// Each frame:
scenes.update(dt: dt)
let overlayAlpha = scenes.fadeAlpha             // draw fadeColor with this alpha
```

- **Single** loads call `unloadAll()` first. **Additive** loads keep existing scenes. A loaded scene becomes active only if none is active, or when loaded in single mode.
- `unload(_:)` destroys the scene's members, except those with `PersistAcrossScenes`, then fires `onSceneUnloaded`. Destruction is recursive, so only the roots of the doomed set are destroyed.
- `save(_:)` serialises one scene's members. `adopt(_:)` assigns a spawned entity to the active scene.
- `transition(to:mode:transition:)` starts a fade. Zero duration loads at once. A pending transition is replaced silently.
- `fadeAlpha` rises from 0 to 1 over the first half, the swap happens at the midpoint, and it falls back to 0.

**Limitation.** `PersistAcrossScenes` only protects the entity from being selected for destruction. A persistent child of a scene-owned root is destroyed with that root.

## 18. Performance, ownership and threading

- Add, remove, lookup and replace are O(1) amortised. Iteration is linear over contiguous arrays.
- Multi-component `forEach` scans only the smallest store and does O(1) lookups in the others.
- Each `forEach` visit copies components in and out, so keep components small.
- `entities(with:)`, `entities(tagged:)`, `entities(inGroup:)`, `find(named:)` and `rootEntities` allocate or scan, and `rootEntities` also sorts. Cache their results.
- `worldMatrix(of:)` costs O(depth). `WorldTransform` is O(1) to read.
- This document gives no measured figures. See [21-Performance.md](21-Performance.md).
- A `World` is owned by the engine or a test, and is mutated from one thread at a time, normally the main thread. It has no internal locking. Parallelism happens only inside `withDenseStorage`, through `Jobs.parallelFor`. The closure is `@Sendable` and must not capture the world.
- `ComponentRegistry` is lock-protected. `SceneDocument` is `Sendable`, so it may be decoded off the main thread. `SystemScheduler` holds the world weakly.

## 19. Limitations

- **Limitation: iteration order.** Dense order changes on removal. Do not depend on it.
- **Limitation: `createEntity(named:transform:parent:)` during iteration.** The entity exists at once, but its `Name` and `Transform` are deferred, and `setParent` is partly immediate. Use `deferStructural` for a complete, predictable creation.
- **Limitation: persistence and recursive destroy.** A persistent child of a scene root is destroyed with the root (see [section 17](#17-scene-management)).
- **Limitation: ancestor limit.** `worldMatrix(of:)` stops silently after 1024 ancestors.
- **Limitation: no migration.** Only the current `formatVersion` is accepted. Other versions are rejected.
- **Limitation: references outside a saved set** become `.null` after loading.
- **Limitation: `clear()`** does not notify `onEntityDestroyed`.
- **Limitation: `rootEntities` order.** Its comment says creation order, but the code sorts by entity index. After slot reuse, index order is not creation order.
- **Limitation: no internal locking.** Parallel code is restricted as described in [section 18](#18-performance-ownership-and-threading).

## 20. Related documents

- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): frame phases, fixed-step timing and system ordering.
- [08-Rendering-3D.md](08-Rendering-3D.md): consumption of the render components.
- [13-Physics.md](13-Physics.md): physics components and the ECS bridge.
- [14-Input.md](14-Input.md): input read in `earlyUpdate` or `update` systems.
- [18-Assets.md](18-Assets.md): `AssetID` values used by render and prefab components.
- [20-Gameplay-API.md](20-Gameplay-API.md): gameplay conventions built on this layer.
- [21-Performance.md](21-Performance.md): measuring scene and system cost.
- [29-API-Reference.md](29-API-Reference.md): the complete API listing.
