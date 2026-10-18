# Third-Party Notices

## Bundled code

Ferox currently bundles no third-party code. No source files, binaries, shaders, fonts or other assets in this repository originate from a third party under a separate licence.

## System frameworks

Ferox links against Apple system frameworks only. These are provided by macOS and the Xcode SDK and are used under Apple's SDK terms, not redistributed with Ferox:

- Metal
- MetalKit
- MetalFX
- MetalPerformanceShaders
- GameController
- AVFoundation
- CoreText
- CoreGraphics
- AppKit
- SwiftUI

## Policy for adding dependencies

Contributors may add a third-party dependency only when it is licensed under one of the following permissive licences:

- MIT
- BSD (2-clause or 3-clause)
- Apache-2.0
- Zlib

Copyleft licences (for example GPL, LGPL, AGPL or MPL) and proprietary or source-available licences are not accepted.

Each accepted dependency must be recorded in this file, in its own section, with:

1. the name of the dependency and the component or module that uses it;
2. the exact version or commit that is vendored or pinned;
3. the licence identifier and a link to the full licence text in the upstream project;
4. the copyright notice required by that licence, reproduced verbatim.

A pull request that adds a dependency must update this file, and the `NOTICE` file where the licence requires it.

## Accepted dependencies

None.
