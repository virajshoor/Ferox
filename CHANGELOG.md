# Changelog

All notable changes to Ferox are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased

This version has not been released yet.

### Added

- Initial engine foundation:
  - Math library
  - ECS scene system
  - Metal renderer, with 2D sprite batching and 3D PBR forward+ rendering
  - Physics for 2D and 3D
  - Input
  - UI
  - Audio
  - Animation
  - Particles
  - Asset pipeline
  - Hybrid ray tracing
  - Anti-aliasing: MSAA, FXAA, SMAA and TAA
  - MetalFX upscaling
  - Editor
  - Networking foundations
  - Benchmarks (`FeroxBenchmarks`)
- Editor application (`FeroxEditor`) with hierarchy, inspector, Play/Pause/Step/Stop, snapshot undo/redo and scene files.
- Diagnostics tool (`FeroxDiag`) reporting GPU capabilities and resolved graphics presets.
- Examples: `HelloFerox`, `Platformer2D` and `Showcase3D`, all runnable headless.
- Test targets for every module, plus integration tests for the engine, editor and launcher.
- Documentation: README and 29 guides under `Docs/`.

### Fixed

- `RenderMath.groups` returned a wrong dispatch size when the group size was zero or negative.

### Removed

- The unused `DynamicResolutionController` in `FeroxCore`, which clashed with the renderer's type of the same name in `FeroxRender`.

### Known issues

- The code has not yet been compiled or run on Apple hardware. See [Limitations and Roadmap](Docs/28-Limitations-and-Roadmap.md).
