# User Interface

Ferox's in-game UI is a small retained element tree in the `FeroxUI` module. Each frame, `UIContext` lays the tree out, routes input (pointer, keyboard and controller), advances animations, and produces a backend-neutral `UIDrawList`. The Metal renderer turns that list into vertices in `UIBatcher` and draws it in the present pass. Apart from the Core Text font provider, the module is platform-independent Swift.

The UI works in points with the origin at the top left. Conversion to pixels happens in the renderer, using `UIContext.scaleFactor` (the display's backing scale multiplied by the user's UI scale). Nothing in this document has been compiled or run on hardware. The Metal path in particular is unverified; see [Validation status](#15-validation-status).

The UI is separate from the ECS. Elements are reference types with identity, which matters for focus, hover and animation. They are not entities and not sprites. For the ECS side see [06-Scene-and-Entities.md](06-Scene-and-Entities.md). For the frame order that places `ui.update` and the draw call, see [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md). Input sources and actions are described in [14-Input.md](14-Input.md).

## Contents

1. [Status and scope](#1-status-and-scope)
2. [The element tree](#2-the-element-tree)
3. [Layout](#3-layout)
4. [Input routing and focus](#4-input-routing-and-focus)
5. [Popups](#5-popups)
6. [Built-in controls](#6-built-in-controls)
7. [Text](#7-text)
8. [Drawing and the draw list](#8-drawing-and-the-draw-list)
9. [Batching and the Metal pass](#9-batching-and-the-metal-pass)
10. [Theme, animation and accessibility](#10-theme-animation-and-accessibility)
11. [Code examples](#11-code-examples)
12. [Limitations](#12-limitations)
13. [Validation status](#13-validation-status)
14. [Related documents](#14-related-documents)

## 1. Status and scope

| Area | Status |
| --- | --- |
| Element tree, anchors, stacks | Implemented: `UIElement.swift`, `UIContext.swift`. |
| Built-in controls | Implemented: `Controls.swift`. |
| Rich text and font providers | Implemented: `Text.swift`, `CoreTextFonts.swift`. Core Text is used only where `CoreText` is available. |
| Draw list | Implemented: `DrawList.swift`. |
| Batching and Metal UI pass | Implemented: `UIBatcher.swift`, `OverlayPasses.swift` (`encodeUI`), `UI.metal`. **Not verified on hardware.** |
| Platform accessibility bridge | **Not implemented.** `UIContext.accessibilityNodes()` produces a flattened list, but nothing in this repository consumes it. |
| Clipboard | **Not provided.** `UIContext.clipboard` is `nil` by default and no `UIClipboard` implementation exists in the repository. |
| Automated tests | None in `Tests/` exercise `FeroxUI` or `UIBatcher`. |

## 2. The element tree

`UIContext` owns two elements. `root` holds the screens and HUD layers that the game adds with `ui.add(_:)`. `popupLayer` is a full-screen child of `root` with `zIndex` 10 000, so popups always draw and hit-test above everything else. `add(_:)` re-appends the popup layer after each addition to keep it last.

`UIElement` is the base class. Subclasses override:

- `contentSize(available:context:)` for intrinsic size (`.fit` sizing).
- `arrangeChildren(context:)` to place children.
- `draw(_:context:)` to emit draw commands for the element itself.
- `handle(_:context:)` to consume a `UIEvent`; return `true` to stop propagation.
- `tick(dt:context:)` for per-frame work such as caret blinking.
- `isFocusable` and `isScrollable`.

Events bubble from the hit element up through its parents until one handles them. The default `handle` only reacts to `.activate` by calling `onClick`.

`UIContext.update(input:dt:viewportPoints:)` runs, in order: size update, `animator.update`, `layout()`, input routing (if input is supplied), and `tick`. Layout is recomputed every frame. There is no dirty tracking.

## 3. Layout

Each axis is sized by a `SizeSpec`:

| Case | Meaning |
| --- | --- |
| `.fixed(Float)` | Exactly this many points. |
| `.fit` | Size to content. |
| `.fill(Float)` | Share the remaining space in a stack by weight, or fill the parent. |
| `.percent(Float)` | Fraction of the parent's available size. |

Without a stack, children overlay each other inside the parent's `contentRect` (`padding` removed). An element with `anchors` set is positioned by `Anchors` instead of by its parent's layout. `Anchors` has normalised `min` and `max` corners plus point offsets. `Anchors.point(_:size:pivot:offset:)` builds a fixed-size element at an anchor point, which is how the examples place their HUD labels.

`UIStack` lays children out along one axis with `spacing`, cross-axis `alignment` (`UIAlignment`: `start`, `center`, `end`, `stretch`) and `justify` (`start`, `center`, `end`, `spaceBetween`). `justify` applies only when no child uses `.fill`. Children with `.fill(weight)` split the free space in proportion to their weights.

Margins and padding are `EdgeInsets`. `minSize` and `maxSize` clamp the measured size. `UIButton` raises its minimum size to `UITheme.minimumHitSize` (24 points by default).

`UIScrollView` clips its content, offsets it by `scrollOffset`, and clamps the offset to `maxOffset`. `UIListView` is virtualised: only rows intersecting the viewport are created, and every row has the fixed `rowHeight`.

## 4. Input routing and focus

`UIContext` consumes `InputState` once per frame. The key behaviour is:

- **Pointer.** The element under the pointer (`hitTest`) receives `.pointerDown`. While the button is held, the captured element receives `.pointerDrag`. On release it receives `.pointerUp(_:inside:)`. Clicking a focusable element focuses it. Clicking a non-focusable element clears focus, except for scroll views.
- **Hit testing.** Popups are tested first, in reverse draw order. An element is hit only if it is interactive: focusable, has an `onClick`, is scrollable, or has a `background`. Clipping is respected.
- **Wheel.** `.scroll` goes to the nearest scrollable ancestor of the element under the pointer.
- **Keyboard.** Text goes to the focused element as `.text`. Tab and Shift-Tab move focus in tree order. Arrow keys navigate spatially; Return dispatches `.activate`; Escape cancels (closes the top popup, otherwise clears focus). Space activates the focused element unless it is a `UITextField`.
- **Controller.** The D-pad and left stick navigate with auto-repeat: 0.4 s after the direction changes, then every 0.12 s while it is held. The focused element is offered a `.navigate` event first, so a slider can consume it. South activates; east cancels.

Spatial navigation picks the focusable element that is ahead of the current one in the requested direction. Candidates must be more than one point ahead. The score is the distance along the direction plus twice the perpendicular offset.

`UIContext.wantsKeyboard` is `true` while a `UITextField` has focus. Games should ignore gameplay keys in that case, as the editor does. `pointerOverUI` tells the game whether the pointer is over UI, so world clicks can be ignored.

`focus(_:)` scrolls the new focus into view by calling `scrollToVisible(_:)` on each scroll-view ancestor.

## 5. Popups

`presentPopup(_:owner:)` adds an element to `popupLayer`. `dismissPopup(_:)` removes it. `hasPopup` reports whether any popup is open.

Only the top popup receives focus traversal: `focusables()` searches the last popup when one is open. Escape dismisses the top popup. A click outside an open `UIDropdown` menu closes it. Other popups are not dismissed by an outside click; the game must do that itself.

`UIDropdown` builds its menu as a `UIStack` of borderless `UIButton`s, anchored under the dropdown and presented as a popup. The menu is a plain stack with no scroll container, so long option lists are not scrollable.

## 6. Built-in controls

| Class | Purpose | Notable members |
| --- | --- | --- |
| `UILabel` | Text, optionally rich. | `text`, `font`, `color`, `alignment`, `wraps`, `richText`, `plainText`. |
| `UIImage` | Texture or atlas region. | `texture` (`AssetID`), `uv`, `tint`, `preserveAspect`. |
| `UIButton` | Push button. | `label`, `style` (`standard`, `primary`, `borderless`), `onClick`. |
| `UIToggle` | Checkbox. | `isOn`, `onChange`, `setOn(_:)`. |
| `UISlider` | Horizontal range control. | `value`, `range`, `step`, `onChange`, `setValue(_:)`, `normalized`. |
| `UITextField` | Single-line editor. | `text`, `placeholder`, `maxLength`, `caret`, `onChange`, `onSubmit`. |
| `UIScrollView` | Vertical scroll container. | `content`, `scrollOffset`, `scroll(by:)`, `scrollToVisible(_:)`. |
| `UIListView` | Virtualised fixed-height list. | `count`, `rowHeight`, `makeRow`, `selectedIndex`, `onSelect`, `select(_:)`. |
| `UIDropdown` | Option picker with popup menu. | `options`, `selectedIndex`, `onChange`, `select(_:)`, `isOpen`. |
| `UIStack` | Linear layout container. | `axis`, `spacing`, `alignment`, `justify`. |

`UISlider` accepts click, drag, keyboard arrows and controller navigation. `setValue(_:)` clamps to the range, applies `step` if set, and calls `onChange` only when the value changes. Assigning `value` directly does not call `onChange`; the editor relies on this to refresh the inspector without creating undo steps.

`UITextField` keeps a caret measured in characters. It accepts `.text` input (newlines are filtered out), supports Backspace and Delete, Home and End, and Command-V and Command-C through `UIClipboard`. Pressing Return calls `onSubmit`. There is no selection range.

`UIListView.count` is observable: setting it clears the realised rows and rebuilds them on the next layout. `select(_:)` scrolls the selected row into view and calls `onSelect`.

## 7. Text

Text is measured and laid out by a `UIFontProvider`, selected by `Engine` at startup. `CoreTextFontProvider` is used when Core Text is available (the normal case on macOS). It shapes text with the system shaper, rasterises glyphs at the current scale into 1024 × 1024 R8 atlas pages, and packs them with shelf allocation. `MonospaceFontProvider` gives deterministic metrics (advance 0.6 × size, line height 1.25 × size) and is intended for tests and headless use.

`RichText` accepts a small markup:

- `<b>` and `<i>` set bold and italic.
- `<color=#RRGGBB>` sets the colour (six hex digits, no alpha).
- `<size=N>` sets the size, for 0 < N ≤ 512.
- `</b>`, `</i>`, `</size>` and `</color>` close the most recent style.

Unknown tags are rendered literally. Malformed markup never fails. Closing tags pop the top of the style stack without checking the tag name, so mismatched markup can apply the wrong style. `UILabel.plainText` strips the markup and is used for accessibility labels.

`UIFontDescriptor` carries a family name, size and bold and italic flags. The family `"SF Pro"`, `"System"` or an empty name maps to the system UI font in the Core Text provider. Any other name is looked up with `CTFontCreateWithName`.

## 8. Drawing and the draw list

`UIContext.draw()` walks the tree in draw order (children sorted by `zIndex`, then insertion order) and appends commands to a `UIDrawList`. The list has four command kinds, plus clip push and pop:

- `rect(frame:color:bottomColor:cornerRadius:borderWidth:borderColor:)` for rounded rectangles with an optional vertical gradient and border.
- `image(frame:texture:uv:tint:cornerRadius:)` for a textured quad.
- `glyphs(atlas:quads:color:)` for a run of glyph quads from one atlas page.
- `pushClip(_:)` and `popClip()`, used for elements with `clipsChildren` and for text fields.

Every element's `opacity` multiplies into the context's opacity stack, so a faded parent fades its children. `offset` and `scale` are visual only: the context temporarily moves the element's frame and its subtree while drawing, then restores it. Layout is not affected.

The draw list discards commands that are fully transparent or fall outside the current clip. `UIScrollView` draws its scrollbar as an overlay after its children.

## 9. Batching and the Metal pass

`UIBatcher.build(_:viewportSize:scale:)` converts a `UIDrawList` into `UIFrameData`: a vertex array, an index array, a list of `UIBatch` draws and the viewport uniforms. Each batch records a texture binding (`none`, `image(AssetID)` or `glyphAtlas(Int)`), a clip rectangle and an index range.

Solid quads do not sample a texture, so they join whichever batch is open. A batch ends only when the texture or the clip changes. Every quad is four vertices and six indices. Each vertex is 80 bytes and carries the position, UV, premultiplied colour, rounded-rectangle parameters (centre, half size, corner radius, border width and mode) and the border colour. The vertex data is written so that the shader can draw signed-distance rounded corners and borders. Solid quads, and image quads with a corner radius, are padded by one point so that anti-aliased edges are not clipped. Glyph quads are not padded.

The Metal side is in `OverlayPasses.swift`. `encodeUI` uses the pipeline `uiVertex` / `uiFragment` from `UI.metal`, with premultiplied blending. It binds the vertex buffer at index 0 and the uniforms at index 1, and sets a scissor rectangle per batch. The glyph texture is an R8 texture re-uploaded whenever its atlas page's `revision` changes. Image textures are fetched through the texture cache in sRGB.

`Renderer.render(world:to:time:deltaTime:ui:)` calls `buildUI` for the present pass, which runs `UIContext.draw()` and `UIBatcher.build` inside `Profiler.shared.scope("Render.UI")`. The renderer's `glyphPages` closure can supply glyph pages if the default is not wanted.

## 10. Theme, animation and accessibility

`UITheme` holds the colours (background, surface, hover and pressed states, border, text, muted text, accent and focus ring), the corner radius, the default font, the spacing and the minimum hit size. `UITheme.highContrast` is a variant with black, white and yellow accents.

`UIContext.userScale` multiplies the UI scale and divides the canvas size, so the same layout can be made larger for accessibility without changing the tree. The value is clamped to at least 0.1 in input conversion.

`UIElement.animate(opacity:offset:scale:duration:easing:context:)` queues a tween. Animations are driven by `UIAnimator`, and a new animation on an element replaces the previous one. `UIEasing` offers `linear`, `easeIn`, `easeOut`, `easeInOut` and `spring`. Animations use unscaled time, because `UIContext.update` is given `ft.unscaledDelta` by the engine.

`accessibilityRole`, `accessibilityLabel` and the `UIContext.accessibilityNodes()` method exist so a platform host can expose the UI to VoiceOver. The repository contains no host code that does so. Treat accessibility as unimplemented.

## 11. Code examples

A pause menu built from the controls. Each class and member exists in `FeroxUI`.

```swift
let menu = UIStack(.vertical, spacing: 12, name: "Pause")
menu.padding = EdgeInsets(all: 20)
menu.background = engine.ui.theme.surface
menu.cornerRadius = engine.ui.theme.cornerRadius
menu.anchors = .point(Vec2(0.5, 0.5), size: Vec2(320, 240), pivot: Vec2(0.5, 0.5))

menu.add(UILabel("Paused", font: UIFontDescriptor(family: "SF Pro", size: 22, bold: true)))
menu.add(UIButton("Resume", style: .primary) { [weak engine] in engine?.clock.isPaused = false })
menu.add(UISlider(value: 0.5, range: 0...1, step: 0.05) { volume in
    print("volume \(volume)")
})
engine.ui.add(menu)
```

A dropdown, and an animated fade-in for the menu:

```swift
let quality = UIDropdown(options: ["Low", "Medium", "High"], selected: 1) { index in
    print("quality index \(index)")
}
menu.add(quality)

menu.opacity = 0
menu.animate(opacity: 1, duration: 0.25, easing: .easeOut, context: engine.ui)
```

A clipboard bridge. The host must supply one for copy and paste to work.

```swift
final class SystemClipboard: UIClipboard {
    func read() -> String? { /* read the platform pasteboard */ nil }
    func write(_ s: String) { /* write to the platform pasteboard */ }
}
engine.ui.clipboard = SystemClipboard()
```

Reading the UI's accessibility tree, for a host that wants to expose it:

```swift
for node in engine.ui.accessibilityNodes() where node.role == .button {
    print(node.label, node.frame, node.isFocused)
}
```

## 12. Limitations

- **No platform accessibility bridge.** The tree is flattened by `accessibilityNodes()`, but no VoiceOver integration exists in the repository.
- **No clipboard implementation.** `UIClipboard` is a protocol only. Without a host implementation, Command-V and Command-C do nothing.
- **Text fields are minimal.** There is no selection range, no marked-text (IME) input and no word-wise movement. Editing is by character.
- **Vertical scrolling only.** `UIScrollView` scrolls on the y axis. `UIListView` requires a fixed row height.
- **Dropdown menus do not scroll.** A long option list grows past the screen.
- **Outside clicks dismiss only dropdowns.** Other popups need the game to dismiss them.
- **Closing rich-text tags are not matched.** `</b>` and `</size>` both pop the top style.
- **Tooltips are stored but not drawn.** `UIElement.tooltip` exists, but nothing in `FeroxUI` renders it.
- **Layout runs every frame.** There is no caching of measured sizes beyond the last measurement, so very large trees pay the full layout cost each frame.
- **Monospaced metrics are not for display.** `MonospaceFontProvider` produces placeholder UVs.
- **Renderer path unverified.** The batching, the UI shader and the glyph atlas upload have not been run on a GPU.

## 13. Validation status

This document was written from the source. No macOS machine or Swift toolchain was available while the engine was written, so nothing here has been compiled, run or measured. No frame times, draw counts or visual results are reported.

The `Tests/` directory contains no tests that exercise `UIContext`, the controls, `RichText`, `UIBatcher` or the Metal UI pass. The CI workflow runs `swift test` on macOS and a filtered set on Linux, but neither filter includes a UI test. The Metal UI pass and the Core Text provider have not been verified on hardware.

## 14. Related documents

- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md) for where `ui.update` and the UI draw sit in the frame.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md) for the ECS, which the UI is deliberately separate from.
- [07-Rendering-2D.md](07-Rendering-2D.md) for the sprite pass that shares the present target with the UI.
- [14-Input.md](14-Input.md) for `InputState`, actions and the controller bindings the UI consumes.
- [18-Assets.md](18-Assets.md) for the `AssetID` values used by `UIImage` and `UIBatch`.
- [20-Gameplay-API.md](20-Gameplay-API.md) for hooking UI into a `Game`.
- [22-Editor.md](22-Editor.md) for an application built entirely from these controls.
- [29-API-Reference.md](29-API-Reference.md) for the complete list of public types.
