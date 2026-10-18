# Animation and Particles

The animation module (`FeroxAnimation`) provides keyframed curves and clips, skeletal poses, an animator state machine with cross-fades and 1D blend trees, property tweens, sequenced timelines, CPU particle emitters and ribbon trails. Everything is driven by systems in the `lateUpdate` phase, and they write results back into ordinary ECS components such as `Transform`, `MaterialOverrides` and `SpriteRenderer`. Animation events and tween and timeline notifications are delivered through the `EventBus`. The particle emitter is a component whose simulation can run on the CPU in this module, or on the GPU in the renderer. The GPU path is outside this repository snapshot.

Entities, components and the scheduler are described in [06-Scene-and-Entities.md](06-Scene-and-Entities.md). Frame phases are in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md). Model and clip import is in [18-Assets.md](18-Assets.md). Rendering of sprites and particles is in [08-Rendering-3D.md](08-Rendering-3D.md).

## Contents

1. [Systems and frame order](#1-systems-and-frame-order)
2. [Curves and easing](#2-curves-and-easing)
3. [Clips, channels and events](#3-clips-channels-and-events)
4. [Skeletons and poses](#4-skeletons-and-poses)
5. [The animator](#5-the-animator)
6. [How AnimationSystem applies results](#6-how-animationsystem-applies-results)
7. [Tweens](#7-tweens)
8. [Timelines](#8-timelines)
9. [Particles](#9-particles)
10. [GPU simulation](#10-gpu-simulation)
11. [Trails](#11-trails)
12. [Registration](#12-registration)
13. [Code examples](#13-code-examples)
14. [Limitations and discrepancies](#14-limitations-and-discrepancies)
15. [Related documents](#15-related-documents)

## 1. Systems and frame order

| System | Phase | `order` | Runs in edit mode | Role |
| --- | --- | --- | --- | --- |
| `AnimationSystem` | `lateUpdate` | -100 | No | Evaluates `Animator` components and writes results. |
| `TimelineSystem` | `lateUpdate` | -95 | No | Advances `TimelinePlayer` components and runs their tracks. |
| `TweenSystem` | `lateUpdate` | -90 | No | Advances `Tween` components. |
| `ParticleSystem` | `lateUpdate` | 50 | Yes | Spawns and integrates CPU particles, or counts GPU spawns. |
| `TrailSystem` | `lateUpdate` | 60 | No | Maintains trail point buffers. |

The `AnimationSystem` source comment says its negative order places animation before transform propagation, so animated transforms are visible to rendering in the same frame. The other systems are ordered relative to it within `lateUpdate`.

`AnimationSystem` needs an `AnimationLibrary`, which holds clips, skeletons and timelines by `AssetID`. On `attach`, it stores the library as a world resource. The timeline system takes the `AnimationSystem` in its initialiser, because it reuses that system's sampling and writing code.

## 2. Curves and easing

`Interpolatable` is the protocol for animatable values. It is implemented for `Float`, `SIMD3<Float>`, `SIMD4<Float>`, `Quat` and `Color`. Each type provides `interpolate` (linear) and `hermite` (cubic Hermite). `Quat` uses spherical interpolation for linear, and normalises after Hermite.

`AnimationCurve<Value>` is a sorted array of `Key` values. Each key has a `time`, a `value`, and optional `inTangent` and `outTangent` for cubic curves. The initialiser sorts the keys by time.

- `sample(_:)` returns `nil` only for an empty curve. Before the first key it returns the first value, and after the last key it returns the last value.
- Between keys it finds the segment by binary search (`segment(_:)`), then evaluates the curve's `CurveInterpolation`.
- `.step` returns the earlier key's value. `.linear` interpolates. `.cubic` uses the Hermite form with the earlier key's out-tangent and the later key's in-tangent, falling back to linear when a tangent is missing.

`Easing` provides standard Penner curves: `linear`, the `easeIn`, `easeOut` and `easeInOut` families of quad, cubic and sine, `easeOutBack`, `easeOutElastic` and `easeOutBounce`. `apply(_:)` clamps its input to [0, 1]. These are used by tweens and by particle curves, not by keyed clips.

```swift
import FeroxAnimation

let fade = AnimationCurve<Float>(keys: [
    .init(0, 0),
    .init(0.25, 1, inTangent: nil, outTangent: nil),
    .init(1, 0),
], interpolation: .linear)
print(fade.sample(0.5) ?? -1)   // 0.666..., between the 0.25 and 1.0 keys
```

## 3. Clips, channels and events

`ChannelTarget` says what a channel drives:

| Target | Value type | Applied by `AnimationSystem` to |
| --- | --- | --- |
| `translation` | `Vec3` | `Transform.position` |
| `rotation` | `Quat` | `Transform.rotation` |
| `scale` | `Vec3` | `Transform.scale` |
| `morphWeight(Int)` | `Float` | **Not applied** (see [Limitations](#14-limitations-and-discrepancies)). |
| `materialFloat(String)` | `Float` | `MaterialOverrides.metallic` or `.roughness` only. |
| `materialColor(String)` | `Color` | `MaterialOverrides.emissive` for `"emissive"`, otherwise `baseColor`. |
| `spriteFrame` | `Float` (frame index) | `SpriteRenderer.uvRect`, from the current state's clip frame list. |

`AnimationChannel` has a `path`, a `target`, and one of four curves (`vec3`, `quat`, `float`, `color`). Its initialisers are `init(path:translation:)`, `init(path:rotation:)`, `init(path:scale:)`, `init(path:target:float:)` and `init(path:target:color:)`. A path is relative to the animated root, with `/` separators, for example `"Hips/Spine/Head"`. The empty path is the root itself.

`AnimationEvent` is a named marker at `time`, with a `name` and a `payload`. `AnimationClip` holds channels, events, `spriteFrames`, a `duration` and a `loops` flag. The duration defaults to the longest channel duration.

`AnimationClip.localTime(_:)` wraps time when `loops` is true, and clamps it otherwise. `events(from:to:)` returns events crossed between two unwrapped times, including those crossed when the clip wraps. It is capped at 1024 results per call.

`AnimationClip.flipbook(name:frames:fps:loops:)` builds a sprite-sheet clip. It has one `spriteFrame` channel with a step curve, one key per frame at `index / fps`, and the frames stored in `spriteFrames`.

```swift
let walkEvents = AnimationClip(
    name: "Walk",
    channels: [AnimationChannel(path: "Hips", translation: hipCurve)],
    events: [AnimationEvent(time: 0.25, name: "footstep", payload: "left"),
             AnimationEvent(time: 0.75, name: "footstep", payload: "right")],
    duration: 1.0, loops: true)

// Playing from 0.9 to 1.3 crosses the loop point at 1.0. The footstep at 0.25 of the
// next cycle (absolute time 1.25) is inside the window, so this prints 1.
print(walkEvents.events(from: 0.9, to: 1.3).count)
```

## 4. Skeletons and poses

`Skeleton` describes a joint hierarchy, with `jointNames`, `parents` (-1 for roots), `inverseBindMatrices` and a `restPose`. Joints are expected to be topologically sorted, parents first. The glTF importer guarantees this for skins.

`Pose` holds one `TRS` per joint:

| Operation | Behaviour |
| --- | --- |
| `blended(with:weight:)` | Interpolates each joint, using normalised linear interpolation for rotations. Weight 0 returns `self` and 1 returns the other pose. |
| `addingAdditive(_:reference:weight:)` | Adds the difference between `additive` and `reference`, scaled by weight. |
| `modelMatrices(_:)` | Model-space joint matrices, multiplying parent-first. |
| `skinningMatrices(_:)` | Model matrices multiplied by the inverse bind matrices. |

`AnimationClip.samplePose(_:at:base:)` samples the clip's TRS channels into a pose. A channel is matched to a joint by the last component of its path, so the joint name is what counts, not the full path.

## 5. The animator

An `Animator` component plays an `AnimatorController`. It is `SerializableComponent`, and holds the parameters, the current state and its time, and the cross-fade bookkeeping.

**Controller.** `AnimatorController` lists `states`, `transitions`, a `defaultState` name and default parameters.

**States.** `AnimatorState` either plays one clip (`init(name:clip:speed:)`), or a 1D blend tree (`init(name:blendTree:parameter:)`). A blend tree is a sorted list of `BlendPoint` values, each with a clip and a `threshold`, driven by a float parameter.

**Parameters.** `AnimatorParameter` has three cases: `float`, `bool` and `trigger`. The setters are `set(_:_:)` for floats and bools, and `trigger(_:)`.

**Transitions.** `AnimatorTransition` has a `from` state (`nil` means any state), a `to` state, `conditions`, a `duration` for the cross-fade, and an optional `exitTime`. Conditions are `greater`, `less`, `isTrue`, `isFalse` and `trigger`.

Rules that follow from the source:

- A transition is tested in declaration order, and the first whose conditions all pass fires. A transition never fires into the state it is already in.
- `isFalse` is true when the parameter is missing. The other conditions are false when the parameter is missing or of another type.
- A `trigger` condition is consumed when the transition that tests it fires, and every trigger condition in that transition is cleared.
- `exitTime` is a normalised time in [0, 1] of the source state. The transition may fire only when the state's fractional progress has reached `exitTime`, or once the state has finished.
- `crossFade(to:duration:)` switches state at once and keeps the previous state for blending. A call with the current state name does nothing.
- `speed` on the animator and on the state both scale the state clock.

**Blend trees.** Samples are chosen by the parameter. Below the first threshold, or above the last, the nearest clip is used. Between two points, both clips are sampled at `phase * duration`, where `phase` is the shared normalised time. The clips therefore stay in step even if their lengths differ, which is what walk and run blends need. The two samples are then blended by the weight between the thresholds.

```swift
// Clips referenced below must be added to the AnimationLibrary first.
let locomotion = AnimatorState(name: "Locomotion", blendTree: [
    AnimatorState.BlendPoint(clip: idleClip.id, threshold: 0),
    AnimatorState.BlendPoint(clip: walkClip.id, threshold: 2),
    AnimatorState.BlendPoint(clip: runClip.id, threshold: 5),
], parameter: "speed")

let controller = AnimatorController(
    states: [locomotion, AnimatorState(name: "Jump", clip: jumpClip.id)],
    transitions: [
        AnimatorTransition(from: "Locomotion", to: "Jump", conditions: [.trigger("jump")], duration: 0.1),
        AnimatorTransition(from: "Jump", to: "Locomotion", conditions: [], duration: 0.2, exitTime: 0.9),
    ],
    defaultState: "Locomotion",
    parameters: ["speed": .float(0)])

world.add(Animator(controller: controller), to: character)
```

**Cross-fade.** While `previousState` is set, both states are sampled and blended with `currentWeight`, which rises from 0 to 1 over `fadeDuration`. The old state is dropped when the fade completes.

## 6. How AnimationSystem applies results

Each frame, `AnimationSystem.update` does the following for every `Animator`:

1. Advances the animator's clock, and tests transitions.
2. Samples the current state. If a previous state is still fading, samples that too, and blends them.
3. Collects clip events that were crossed, but only when the state did not change during the frame.
4. Writes all sampled values to their targets.
5. Enqueues an `AnimationEventFired` on the `EventBus` for each collected event.

Target resolution has two modes.

- **Skinned characters.** If the root has a `SkeletonBinding`, and the library holds its skeleton, a channel is matched by the last path component to a joint index. The entity in that slot of `SkeletonBinding.joints` receives the value. Unmatched channels fall back to path resolution.
- **Path resolution.** A path is resolved from the animator's entity by walking children by `Name`. If a component is missing, the whole subtree is searched for the last component's name. Results are cached per root, and the cache is cleared whenever the world's `structureVersion` changes.

`AnimationEventFired` carries `entity`, `clip` (the state name) and `event`. Only the current state's clip produces events, and only on frames without a state change.

## 7. Tweens

A `Tween` animates one property without a clip. It is `SerializableComponent`, and is initialised with a `Property`, a duration, an easing, a loop mode and a delay.

| `Property` | Writes |
| --- | --- |
| `position(from:to:)` | `Transform.position` |
| `scale(from:to:)` | `Transform.scale` |
| `rotation(from:to:)` | `Transform.rotation`, by slerp |
| `spriteColor(from:to:)` | `SpriteRenderer.color` |

`Tween.Loop` is `once`, `loop` or `pingPong`. In `once` mode, the tween holds its end value when it completes. If `removeOnComplete` is true (the default), the component is removed. A `TweenCompleted` event is enqueued on completion. The other modes continue indefinitely. If `removeOnComplete` is false, the tween stays and `TweenCompleted` is enqueued again on every later frame (see [Limitations](#14-limitations-and-discrepancies)).

```swift
world.add(
    Tween(.position(from: Vec3(0, 0, 0), to: Vec3(0, 2, 0)), duration: 0.4, easing: .easeOutBounce),
    to: pickup)
```

## 8. Timelines

A `Timeline` is a sequence of tracks over a `duration`, stored in the library by `AssetID`. A `TimelinePlayer` component plays it, with `time`, `isPlaying`, `loops` (default `false`) and `speed`.

| Track | Effect |
| --- | --- |
| `animation(path:clip:start:)` | Samples `clip` at `t - start` and applies it to the entity at `path`, between `start` and `start` plus the clip duration. Looping clips are not limited to that span. |
| `activation(path:start:end:)` | Removes `Disabled` from the entity at `path` while the time is in `[start, end)`, and adds it outside that range. |
| `event(time:name:payload:)` | Enqueues `TimelineEventFired` when the time crosses `time`. |

Track paths are resolved from the entity carrying the `TimelinePlayer`. For an `animation` track, the clip's channel paths are then resolved relative to the target entity, not to the player. When a non-looping player reaches the end, it stops at `duration` after evaluating the final tracks.

```swift
let intro = Timeline(name: "Intro", duration: 6, tracks: [
    .activation(path: "Guard", start: 0, end: 4),
    .animation(path: "Door", clip: doorOpen.id, start: 1),
    .event(time: 2.5, name: "bark", payload: "guard_01"),
    .activation(path: "Guard", start: 4, end: 6),
])
library.add(intro)

let cutscene = world.createEntity(named: "Cutscene")   // "Guard" and "Door" are its children
world.add(TimelinePlayer(timeline: intro.id), to: cutscene)
```

## 9. Particles

### Emitter

`ParticleEmitter` is a `SerializableComponent` describing one emitter. Its fields are:

| Group | Fields and defaults |
| --- | --- |
| Emission | `isEmitting` (true), `maxParticles` (1000), `rate` (50 per second), `bursts` (`Burst(time:count:)` list), `duration` (5 s), `loops` (true). |
| Start values | `lifetime` (1...2), `startSpeed` (1...3), `startSize` (0.1...0.2), `startRotation` (0...0), `angularVelocity` (0...0). |
| Shape | `shape`, default `.cone(angle: 0.4, radius: 0.1)`. |
| Forces | `gravity` (zero), `drag` (0), `turbulence` (0), `turbulenceFrequency` (1). |
| Over lifetime | `sizeOverLifetime`, `colorOverLifetime` (`Gradient`), `speedOverLifetime` (curve, default 1). |
| Ground | `collisionPlaneY` (optional), `bounce` (0.3). |
| Rendering | `simulation` (`.cpu` by default), `space` (`.world` or `.local`), `renderMode` (`billboard`, `stretched`, `horizontal`), `texture`, `sheetGrid` (`IVec2Codable`), `sheetFPS`, `blend` (`.additive`), `sortingLayer`. |
| Determinism | `seed` (1). |

`Shape` has these cases: `point`, `sphere(radius:surfaceOnly:)`, `hemisphere(radius:)`, `box(extents:)`, `cone(angle:radius:)` (opening along +Y), `circle(radius:)` (in the XY plane) and `edge(length:)` (along X).

### Pool and state

`ParticlePool` is a reference type holding structure-of-arrays storage for positions, velocities, ages, lifetimes, sizes, rotations, angular velocities and seeds, up to `capacity`. It is not copied through the ECS. Dead particles are removed by swapping the last particle into their slot, so particle order changes.

`ParticleState` is the runtime component. It owns the pool, the emitter clock, the random generator, `pendingGPUSpawn`, and the emitter matrix. It is created automatically by `ParticleSystem` whenever the pool's capacity differs from `maxParticles`. It is not serialised.

### CPU simulation

`ParticleSystem.update` does the following for each emitter in an active hierarchy:

1. Refreshes the emitter matrix from `WorldTransform`.
2. Advances the emitter clock, wrapping it at `duration` if `loops` is true.
3. Computes the spawn count from `rate` (accumulating fractional particles), and from any bursts crossed this step.
4. If `simulation == .gpu`, stores the spawn count in `pendingGPUSpawn` and stops. Otherwise it calls `ParticleSystem.simulate`.

`simulate(_:_:spawn:dt:emitterMatrix:)` is public, so it can run offline. It spawns particles at a shape sample, with a speed along the shape direction. In `.world` space, positions and directions are transformed by the emitter matrix at spawn time. Each step it then ages particles, kills expired ones, applies gravity, a turbulence term, drag, speed over lifetime and integration, and optionally bounces off `collisionPlaneY`. If the pool is full, the spawn is dropped silently.

**Limitation.** In this module, `sizeOverLifetime`, `colorOverLifetime`, `startRotation` and `angularVelocity` are stored per particle or per emitter, but no code here evaluates the size and colour curves. They are for the renderer. See [Limitations](#14-limitations-and-discrepancies).

## 10. GPU simulation

When `simulation == .gpu`, the CPU `ParticleSystem` does **not** simulate or draw particles. It updates the emitter clock and writes the number of particles to spawn this frame into `ParticleState.pendingGPUSpawn`. Simulation and rendering are then performed by the renderer, documented in [08-Rendering-3D.md](08-Rendering-3D.md).

The renderer is not part of this repository snapshot. The GPU path therefore cannot be checked here. Also, nothing in this repository reads `sheetGrid`, `sheetFPS` or `renderMode`, so the flipbook and render-mode options are inputs for the renderer.

## 11. Trails

`TrailRenderer` is a ribbon behind a moving entity. Its fields are `lifetime` (0.5 s), `minVertexDistance` (0.05), `widthOverLifetime`, `color`, `texture`, `blend` (`.additive`) and `maxPoints` (128).

`TrailSystem` keeps a `TrailBuffer` of points and times per trail, in a `TrailState` component. Each update expires points older than `lifetime`. The newest point is a head that follows the entity while it is close to the previous committed point. Once the entity moves far enough, a new head is appended. When the buffer exceeds `maxPoints`, the oldest point is removed. Width and colour are data for the renderer.

## 12. Registration

`ComponentRegistry.registerAnimationComponents()` registers `Animator`, `Tween`, `TimelinePlayer`, `ParticleEmitter` and `TrailRenderer` for scene serialisation. `Animator`, `Tween` and `TimelinePlayer` are registered without a default value, and the particle and trail types with their defaults. `ParticleState` and `TrailState` are runtime-only and are not registered.

Systems are not registered this way. The game adds them to a `SystemScheduler`, and attaches an `AnimationLibrary` to the world.

## 13. Code examples

### A sprite flipbook

```swift
import FeroxAnimation
import FeroxScene

let library = AnimationLibrary()

// A 4 by 2 sprite sheet: eight frames, each a quarter wide and half tall.
let frames: [Rect] = (0..<8).map { i in
    Rect(x: Float(i % 4) * 0.25, y: Float(i / 4) * 0.5, width: 0.25, height: 0.5)
}
let coinSpin = AnimationClip.flipbook(name: "CoinSpin", frames: frames, fps: 12)
library.add(coinSpin)

let coin = world.createEntity(named: "Coin", transform: Transform(position: Vec3(3, 1, 0)))
world.add(SpriteRenderer(texture: sheetID), to: coin)
world.add(Animator(clip: coinSpin.id), to: coin)
// The spriteFrame channel uses the empty path, so it targets the animator's own entity.
```

### A character locomotion blend tree

The controller from [section 5](#5-the-animator) drives the character. Gameplay code sets the parameter each frame, and fires the trigger on a jump.

```swift
func updateCharacter(_ character: Entity, speed: Float, jumpPressed: Bool) {
    world.modify(Animator.self, character) { animator in
        animator.set("speed", speed)
        if jumpPressed { animator.trigger("jump") }
    }
}
```

Clips must be in the library, with the animation `AnimationSystem` reading that same library, before the first frame. The blend tree keeps walk and run in step, so the feet stay in phase across the blend.

### A cutscene timeline

```swift
_ = world.createEntity(named: "Guard", parent: cutscene)
_ = world.createEntity(named: "Door", parent: cutscene)

let scene = Timeline(name: "DoorIntro", duration: 4, tracks: [
    .activation(path: "Guard", start: 0, end: 2.5),
    .animation(path: "Door", clip: doorOpenClip.id, start: 0.5),
    .event(time: 1.0, name: "door_creak", payload: "sfx/creak"),
])
library.add(scene)

world.add(TimelinePlayer(timeline: scene.id), to: cutscene)
```

Subscribe to the `TimelineEventFired` event on the same `EventBus` that the systems enqueue to, and play the sound named in `payload`.

### A fire emitter

```swift
var fire = ParticleEmitter()
fire.rate = 80
fire.loops = true
fire.shape = .cone(angle: 0.25, radius: 0.3)
fire.lifetime = 0.6...1.1
fire.startSpeed = 0.6...1.4
fire.startSize = 0.25...0.45
fire.gravity = Vec3(0, 1.5, 0)        // flames rise
fire.drag = 0.8
fire.turbulence = 0.6
fire.maxParticles = 400
fire.colorOverLifetime = Gradient(Color(1, 0.6, 0.1, 1), Color(0.2, 0.05, 0, 0))
fire.seed = 7

world.add(fire, to: torch)
```

This emitter is `.cpu` by default, so `ParticleSystem` simulates it. The gradient and size curve are for the renderer, as noted in [section 9](#9-particles).

## 14. Limitations and discrepancies

- **Limitation: morph weights are not applied.** `morphWeight` channels are imported and sampled, but `AnimationSystem.apply` ignores them. There is no morph-target rendering in this module.
- **Discrepancy: `materialFloat` names.** The case comment lists "a custom property", but only `"metallic"` and `"roughness"` are applied. Other names still add a `MaterialOverrides` component, with no visible change.
- **Discrepancy: `materialColor` names.** Any name other than `"emissive"` writes `baseColor`, not only the documented `"baseColor"`.
- **Limitation: events are skipped on state-change frames.** Clip events are collected only when the state did not change during the frame. Blend-tree states produce no events.
- **Limitation: sprite frames follow the current state.** A `spriteFrame` channel is applied only if the animator's current state has a clip with `spriteFrames`. During a cross-fade, the outgoing state's frames are not used.
- **Discrepancy: repeated `TweenCompleted`.** A `once` tween with `removeOnComplete` set to false enqueues `TweenCompleted` on every frame after it finishes, because the finished entity is collected on each update.
- **Limitation: no `.fxanim` loader.** `AssetKind` recognises `.fxanim`, but nothing loads it. Clips come from glTF import, or are added to the library in code.
- **Limitation: particle size and colour curves are not evaluated** on the CPU. `renderMode`, `texture`, `sheetGrid` and `sheetFPS` are unread in this repository.
- **Limitation: the GPU path is not in this snapshot.** `pendingGPUSpawn` is set, but nothing here consumes it.
- **Limitation: dropped spawns.** A spawn into a full pool is discarded silently.
- **Limitation: particle order is unstable.** Removal swaps the last particle into the hole.
- **Limitation: ground collision only.** Particles collide only with the horizontal plane at `collisionPlaneY`.
- **Tests.** `Tests/FeroxSubsystemTests/AnimationTests.swift` covers easing, curves, tweens, clips and clip events, flipbooks, and CPU particle simulation and emission. GPU particles are not tested. The tests have not yet been run on a toolchain, so no results are cited.

## 15. Related documents

- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): the `lateUpdate` phase and where animation sits in the frame.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): components, systems, and the scheduler.
- [08-Rendering-3D.md](08-Rendering-3D.md): rendering of sprites, particles and trails, and the GPU particle path.
- [14-Input.md](14-Input.md): input that drives animator parameters and triggers.
- [18-Assets.md](18-Assets.md): importing glTF clips and skeletons, and the `AssetID` values used here.
- [20-Gameplay-API.md](20-Gameplay-API.md): gameplay code that listens for animation and timeline events.
- [21-Performance.md](21-Performance.md): measuring animation and particle cost.
- [29-API-Reference.md](29-API-Reference.md): the complete API listing.
