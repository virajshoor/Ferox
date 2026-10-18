# Contributing to Ferox

Thank you for your interest in Swift Engine Ferox (Ferox for short). This guide covers the development setup, the conventions we follow and what we expect from pull requests.

By contributing, you agree that your contributions are licensed under the Apache License, Version 2.0, as described in `LICENSE`. Participation in the project is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Development setup

Requirements:

- macOS 14 or later (Apple Silicon is the primary target)
- Xcode 15.3 or later, which provides Swift 5.10 or later
- Xcode command-line tools (`xcode-select --install`)

Build and test from the command line:

```sh
swift build
swift test
```

To work in Xcode, open `Package.swift` directly. Xcode resolves the package and makes the targets available to build and run.

GPU-backed tests need a Mac with a Metal device, so they cannot run on the Linux CI job. The platform-independent modules are checked there.

> **Verification status.** Ferox was written without access to a Mac or a Swift toolchain. The sources and shaders have been syntax-checked, but nothing has yet been compiled, tested or profiled. The first build on real hardware will very likely surface compile errors; fixing them is a welcome first contribution.

### Test targets

| Target | Covers |
| --- | --- |
| `FeroxMathTests` | Vectors, quaternions, matrices, geometry, colour, random numbers |
| `FeroxCoreTests` | Time, events, logging, graphics settings and the feature resolver, data model |
| `FeroxSceneTests` | World, hierarchy and transforms, serialisation, systems and scene manager |
| `FeroxPhysicsTests` | 2D and 3D worlds and the ECS bridge |
| `FeroxSubsystemTests` | Input, animation and particles, assets, networking, UI, audio |
| `FeroxRenderTests` | The CPU side of the renderer: render maths, uniforms, dynamic resolution, sprite batching, scene extraction |
| `FeroxIntegrationTests` | Engine lifecycle, editor session, launcher |

Run one target with `swift test --filter FeroxPhysicsTests`.

### Tools

- `swift run FeroxDiag` prints the GPU's capabilities and how each graphics preset resolves (`--json` for machine-readable output, `--render` for an offscreen render smoke test).
- `swift run FeroxEditor` opens the editor.
- `swift run HelloFerox --headless --frames 120` runs an example without a window.

## Branches

Branch from `main` and do not push directly to `main`. Use a lowercase, hyphen-separated name prefixed with the type of change:

- `feat/<short-description>`
- `fix/<short-description>`
- `docs/<short-description>`
- `perf/<short-description>`
- `refactor/<short-description>`
- `test/<short-description>`
- `chore/<short-description>`

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):

```text
feat(renderer): add 2D sprite batching
```

Use one of these types: `feat`, `fix`, `docs`, `perf`, `refactor`, `test`, `chore`. The scope is optional but recommended. Write the subject in the imperative mood and keep it to 72 characters or fewer. Use the body to explain why a change was made.

## Pull request checklist

Before requesting review, confirm that your pull request:

- [ ] includes tests for new behaviour and `swift test` passes locally;
- [ ] updates documentation, including `///` comments on public API and any affected pages under `Docs/`;
- [ ] adds an entry under `[Unreleased]` in `CHANGELOG.md`;
- [ ] contains no secrets, credentials, signing profiles or machine-specific paths;
- [ ] contains no generated files, such as build products, DerivedData or local benchmark results;
- [ ] is formatted with swift-format.

The pull request template repeats this list.

## Coding style

- Indent with 4 spaces and use LF line endings. `.editorconfig` defines these settings.
- Formatting is defined by `.swift-format` at the repository root. Check it with `swift format lint --recursive Sources Tests`, and apply it with `swift format format --in-place --recursive Sources Tests`.
- Prefer value types (`struct` and `enum`) and immutability. Use classes only where identity or reference semantics are required.
- Do not use force unwraps (`!`) or `try!` in engine code. Propagate errors with `throws`, or handle missing values explicitly.
- Document every public declaration with `///` comments.

## Adding a shader

1. Add the Metal source file to the renderer's shader resources, following the layout of existing shaders. Check `Package.swift` for how resources are declared.
2. Keep CPU-side structures and their Metal counterparts in sync. Field order, types and alignment must match exactly.
3. Add a test that compiles the shader or builds the pipeline that uses it.
4. Document the shader if it is part of the public rendering behaviour.

## Running benchmarks

Benchmarks must be run in release configuration, because debug timings are not meaningful:

```sh
swift run -c release FeroxBenchmarks
```

Pass `--output BenchmarkResults/<name>.local.json` to write JSON results; `--quick` runs a shorter pass and `--filter <substring>` selects benchmarks. Files matching `BenchmarkResults/*.local.json` are ignored by Git, so use that suffix for local runs you do not intend to commit. When you quote numbers in a pull request, state the Mac model, chip, macOS version and Ferox commit. Numbers from hosted CI runners are not representative of Apple Silicon hardware.

## Reporting security issues

Do not open a public issue, pull request or discussion for a suspected security vulnerability. Follow the private reporting process described in [SECURITY.md](SECURITY.md).
