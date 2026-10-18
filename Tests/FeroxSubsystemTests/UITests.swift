/// Tests for the immediate-mode UI tree: stack layout, pointer and keyboard routing into controls,
/// list virtualisation, focus navigation, monospace text measurement and rich-text parsing. Layout is
/// driven through `UIContext.update` with a fixed viewport; pointer input is injected through
/// `InputSystem`, so no platform backend or CoreText is involved.
import XCTest
import FeroxCore
@testable import FeroxInput
@testable import FeroxUI

final class UITests: XCTestCase {

    /// Lays out `ctx` for an 800 x 600 viewport with no pointer input.
    private func layOut(_ ctx: UIContext, width: Float = 800, height: Float = 600) {
        ctx.update(input: nil, dt: 0, viewportPoints: Vec2(width, height))
    }

    /// Vertical stack places fixed-size children one after another separated by the spacing.
    func testVerticalStackPlacesChildrenWithSpacing() {
        let ctx = UIContext()
        let first = UIElement(name: "first")
        first.width = .fixed(100)
        first.height = .fixed(40)
        let second = UIElement(name: "second")
        second.width = .fixed(100)
        second.height = .fixed(40)
        let stack = UIStack(.vertical, spacing: 10, alignment: .start, [first, second])
        stack.anchors = .fill
        ctx.add(stack)
        layOut(ctx)

        XCTAssertEqual(first.frame.origin.y, 0, accuracy: 1e-4)
        XCTAssertEqual(second.frame.origin.y, 50, accuracy: 1e-4)
        XCTAssertEqual(second.frame.width, 100, accuracy: 1e-4)
        XCTAssertEqual(second.frame.height, 40, accuracy: 1e-4)
    }

    /// A fill child in a horizontal stack takes the space left after fixed siblings.
    func testHorizontalFillChildTakesRemainingSpace() {
        let ctx = UIContext()
        let fixed = UIElement(name: "fixed")
        fixed.width = .fixed(50)
        fixed.height = .fixed(20)
        let flexible = UIElement(name: "flexible")
        flexible.width = .fill(1)
        flexible.height = .fixed(20)
        let row = UIStack(.horizontal, spacing: 0, alignment: .start, [fixed, flexible])
        row.width = .fixed(300)
        row.height = .fixed(20)
        ctx.add(row)
        layOut(ctx)

        XCTAssertEqual(flexible.frame.origin.x, 50, accuracy: 1e-4)
        XCTAssertEqual(flexible.frame.width, 250, accuracy: 1e-4)
    }

    /// Centre justification offsets a stack's children to the middle of its free space.
    func testCenterJustifyCentresChildrenInFreeSpace() {
        let ctx = UIContext()
        let child = UIElement(name: "child")
        child.width = .fixed(100)
        child.height = .fixed(40)
        let stack = UIStack(.vertical, spacing: 0, alignment: .start, [child])
        stack.justify = .center
        stack.anchors = .fill
        ctx.add(stack)
        layOut(ctx)

        XCTAssertEqual(child.frame.origin.y, 280, accuracy: 1e-4)
    }

    /// A button fires its action when the pointer is released over it, not when it is pressed.
    func testButtonFiresOnReleaseNotOnPress() {
        let ctx = UIContext()
        var clicks = 0
        let button = UIButton("OK", action: { clicks += 1 })
        let stack = UIStack(.horizontal, spacing: 0, alignment: .start, [button])
        stack.anchors = .fill
        ctx.add(stack)
        let input = InputSystem()
        layOut(ctx)

        let p = button.frame.center
        input.enqueue(.mouseMove(position: Vec2Codable(p.x, p.y), delta: Vec2Codable(0, 0)))
        input.enqueue(.mouseDown(.left, clickCount: 1))
        input.beginFrame()
        ctx.update(input: input.state, dt: 0, viewportPoints: Vec2(800, 600))
        XCTAssertEqual(clicks, 0)

        input.enqueue(.mouseUp(.left))
        input.beginFrame()
        ctx.update(input: input.state, dt: 0, viewportPoints: Vec2(800, 600))
        XCTAssertEqual(clicks, 1)
    }

    /// A toggle flips on an inside release or activation and reports only real changes.
    func testToggleFlipsOnReleaseAndReportsChanges() {
        let ctx = UIContext()
        var states: [Bool] = []
        let toggle = UIToggle("Sound", isOn: false) { states.append($0) }

        XCTAssertTrue(toggle.handle(.pointerUp(Vec2.zero, inside: true), context: ctx))
        XCTAssertTrue(toggle.isOn)
        _ = toggle.handle(.pointerUp(Vec2.zero, inside: false), context: ctx)
        XCTAssertTrue(toggle.isOn)
        toggle.setOn(true)
        toggle.setOn(false)
        XCTAssertEqual(states, [true, false])
    }

    /// A slider takes its value from the pointer position and steps with the keyboard.
    func testSliderSetsValueFromPointerAndKeyboard() {
        let ctx = UIContext()
        var values: [Float] = []
        let slider = UISlider(value: 0, range: 0...1, onChange: { values.append($0) })
        slider.width = .fixed(216)
        slider.height = .fixed(20)
        let stack = UIStack(.vertical, alignment: .start, [slider])
        stack.anchors = .fill
        ctx.add(stack)
        layOut(ctx)
        XCTAssertEqual(slider.frame.width, 216, accuracy: 1e-4)

        _ = slider.handle(.pointerDown(Vec2(108, 10), clickCount: 1), context: ctx)
        XCTAssertEqual(slider.value, 0.5, accuracy: 1e-4)
        _ = slider.handle(.key(.right, modifiers: []), context: ctx)
        XCTAssertEqual(slider.value, 0.55, accuracy: 1e-4)
        XCTAssertEqual(values.count, 2)
    }

    /// A stepped slider snaps values to the nearest step and clamps to its range.
    func testSteppedSliderSnapsToNearestStep() {
        let slider = UISlider(value: 0, range: 0...1, step: 0.25)
        slider.setValue(0.3)
        XCTAssertEqual(slider.value, 0.25, accuracy: 1e-5)
        slider.setValue(0.9)
        XCTAssertEqual(slider.value, 1, accuracy: 1e-5)
        slider.setValue(5)
        XCTAssertEqual(slider.value, 1, accuracy: 1e-5)
    }

    /// A dropdown reports only changes to a valid option index.
    func testDropdownNotifiesOnlyOnValidChange() {
        var picks: [Int] = []
        let dropdown = UIDropdown(options: ["A", "B", "C"], selected: 0, onChange: { picks.append($0) })
        dropdown.select(0)
        dropdown.select(2)
        dropdown.select(7)
        XCTAssertEqual(dropdown.selectedIndex, 2)
        XCTAssertEqual(picks, [2])
    }

    /// A list view only builds rows for the visible window, not for all 1000 items.
    func testListViewBuildsOnlyVisibleRows() {
        let ctx = UIContext()
        var built = 0
        let list = UIListView(count: 1000, rowHeight: 20) { i in
            built += 1
            return UILabel("row \(i)")
        }
        list.anchors = .fill
        ctx.add(list)
        layOut(ctx, width: 800, height: 100)

        XCTAssertEqual(list.children.count, 6)
        XCTAssertEqual(built, 6)
    }

    /// Scrolling recycles rows that leave the window, and selecting an offscreen row scrolls it into view.
    func testListViewScrollsAndSelectionRevealsRow() {
        let ctx = UIContext()
        var selections: [Int] = []
        let list = UIListView(count: 1000, rowHeight: 20) { i in UILabel("row \(i)") }
        list.onSelect = { selections.append($0) }
        list.anchors = .fill
        ctx.add(list)
        layOut(ctx, width: 800, height: 100)

        _ = list.handle(.scroll(Vec2(0, -60), precise: true), context: ctx)
        XCTAssertEqual(list.scrollOffset, 60, accuracy: 1e-4)
        ctx.layout()
        XCTAssertEqual(list.children.count, 6)
        XCTAssertEqual(list.children.map(\.frame.minY).min() ?? -1, 0, accuracy: 1e-4)

        list.select(10)
        XCTAssertEqual(list.selectedIndex, 10)
        XCTAssertEqual(list.scrollOffset, 120, accuracy: 1e-4)
        XCTAssertEqual(selections, [10])
    }

    /// Focus moves through focusable elements in tree order and wraps around at the end.
    func testFocusNextCyclesThroughFocusables() {
        let ctx = UIContext()
        let first = UIButton("One")
        let second = UIButton("Two")
        let column = UIStack(.vertical, spacing: 4, alignment: .start, [first, second])
        column.anchors = .fill
        ctx.add(column)
        layOut(ctx)
        XCTAssertEqual(ctx.focusables().count, 2)

        ctx.focusNext()
        XCTAssertTrue(ctx.focused === first)
        ctx.focusNext()
        XCTAssertTrue(ctx.focused === second)
        ctx.focusNext()
        XCTAssertTrue(ctx.focused === first)
    }

    /// Spatial navigation moves focus to the neighbour in the requested direction and stays put when there is none.
    func testNavigateMovesFocusSpatially() {
        let ctx = UIContext()
        let left = UIButton("Left")
        let right = UIButton("Right")
        let row = UIStack(.horizontal, spacing: 40, alignment: .center, [left, right])
        row.anchors = .fill
        ctx.add(row)
        layOut(ctx)

        ctx.focus(left)
        ctx.navigate(Vec2(1, 0))
        XCTAssertTrue(ctx.focused === right)
        ctx.navigate(Vec2(-1, 0))
        XCTAssertTrue(ctx.focused === left)
        ctx.navigate(Vec2(0, 1))
        XCTAssertTrue(ctx.focused === left)
    }

    /// Monospace metrics use 0.6 x size advances and 1.25 x size line heights, and word wrap breaks at the last space.
    func testMonospaceMeasurementAndWordWrap() {
        let provider = MonospaceFontProvider()
        let font = UIFontDescriptor(family: "mono", size: 10)
        XCTAssertEqual(provider.lineHeight(font), 13, accuracy: 1e-4)

        let size = provider.measure([TextRun(text: "abcd", font: font, color: nil)], maxWidth: nil)
        XCTAssertEqual(size.x, 24, accuracy: 1e-3)
        XCTAssertEqual(size.y, 13, accuracy: 1e-3)

        let carets = provider.caretPositions("ab", font: font)
        XCTAssertEqual(carets.count, 3)
        XCTAssertEqual(carets[2], 12, accuracy: 1e-3)

        let wrapped = provider.measure([TextRun(text: "aaa bbb", font: font, color: nil)], maxWidth: 30)
        XCTAssertEqual(wrapped.x, 18, accuracy: 1e-3)
        XCTAssertEqual(wrapped.y, 26, accuracy: 1e-3)
    }

    /// Rich text applies bold and colour tags to runs, and plain text strips known markup but keeps unknown tags.
    func testRichTextParsesStylesAndStripsMarkup() {
        let base = UIFontDescriptor(family: "mono", size: 10)
        let runs = RichText.parse("<b>Hi</b> <color=#FF0000>there</color>", base: base)
        XCTAssertEqual(runs.map(\.text), ["Hi", " ", "there"])
        XCTAssertTrue(runs[0].font.bold)
        XCTAssertFalse(runs[1].font.bold)
        XCTAssertNotNil(runs[2].color)

        XCTAssertEqual(RichText.plainText("<i>a</i><size=20>b</size>c"), "abc")
        XCTAssertEqual(RichText.plainText("<unknown>x"), "<unknown>x")
    }
}
