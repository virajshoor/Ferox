import FeroxCore
/// Tests for the input layer: action evaluation through maps and contexts, edge detection across
/// frames, vector normalisation, gamepad and mouse bindings, rebinding, serialisation and dead zones.
/// Input is injected through `InputSystem.enqueue`, so no platform backend is involved.
import XCTest

@testable import FeroxInput

final class InputTests: XCTestCase {

    /// Input system with the default gameplay and UI maps registered.
    private func makeInput() -> InputSystem {
        let input = InputSystem()
        input.addMap(.defaultGameplay)
        input.addMap(.defaultUI)
        return input
    }

    /// Queues the given events and advances the input system by one frame.
    private func runFrame(_ input: InputSystem, _ events: InputEvent...) {
        for e in events { input.enqueue(e) }
        input.beginFrame()
    }

    private func down(_ k: Key) -> InputEvent { .keyDown(k, repeat: false, modifiers: []) }
    private func up(_ k: Key) -> InputEvent { .keyUp(k, modifiers: []) }

    /// The default gameplay map defines the standard action set with the expected kinds.
    func testDefaultGameplayMapDefinesStandardActions() {
        let map = ActionMap.defaultGameplay
        XCTAssertEqual(map.actions.map(\.name), ["Move", "Look", "Jump", "Fire", "Interact", "Sprint", "Pause"])
        XCTAssertEqual(map.actions.first { $0.name == "Move" }?.kind, .vector2)
        XCTAssertEqual(map.actions.first { $0.name == "Jump" }?.kind, .button)
    }

    /// A key pressed this frame reports both isPressed and wasPressed.
    func testKeyPressSetsPressedAndWasPressedOnFirstFrame() {
        let input = makeInput()
        runFrame(input, down(.space))
        XCTAssertTrue(input.isPressed("Jump"))
        XCTAssertTrue(input.wasPressed("Jump"))
    }

    /// wasPressed is an edge flag: it is cleared on the next frame while the key is still held.
    func testWasPressedIsClearedWhileKeyIsHeld() {
        let input = makeInput()
        runFrame(input, down(.space))
        runFrame(input)
        XCTAssertTrue(input.isPressed("Jump"))
        XCTAssertFalse(input.wasPressed("Jump"))
    }

    /// Releasing a key clears isPressed and reports wasReleased for exactly one frame.
    func testReleaseSetsWasReleasedOnce() {
        let input = makeInput()
        runFrame(input, down(.space))
        runFrame(input, up(.space))
        XCTAssertFalse(input.isPressed("Jump"))
        XCTAssertTrue(input.wasReleased("Jump"))
        runFrame(input)
        XCTAssertFalse(input.wasReleased("Jump"))
    }

    /// Two composite keys pressed diagonally yield a unit-length move vector.
    func testDiagonalMoveIsNormalised() {
        let input = makeInput()
        runFrame(input, down(.w), down(.d))
        let v = input.vector("Move")
        XCTAssertEqual(v.length, 1, accuracy: 1e-4)
        XCTAssertEqual(v.x, 0.7071, accuracy: 1e-3)
        XCTAssertEqual(v.y, 0.7071, accuracy: 1e-3)
    }

    /// A single composite key produces an unnormalised unit vector along its axis.
    func testSingleKeyMoveGivesAxisVector() {
        let input = makeInput()
        runFrame(input, down(.w))
        let v = input.vector("Move")
        XCTAssertEqual(v.x, 0, accuracy: 1e-5)
        XCTAssertEqual(v.y, 1, accuracy: 1e-5)
    }

    /// Mouse motion drives the Look action, scaled by the binding and with the Y axis inverted.
    func testMouseDeltaDrivesLookWithScaleAndInvertedY() {
        let input = makeInput()
        runFrame(input, .mouseMove(position: Vec2Codable(0, 0), delta: Vec2Codable(10, 5)))
        let look = input.vector("Look")
        XCTAssertEqual(look.x, 1, accuracy: 1e-4)
        XCTAssertEqual(look.y, -0.5, accuracy: 1e-4)
    }

    /// The south face button of a connected gamepad drives the Jump action.
    func testGamepadButtonDrivesAction() {
        let input = makeInput()
        runFrame(input, .gamepadConnected(id: 0, name: "Test Pad"), .gamepadButton(id: 0, .south, pressed: true))
        XCTAssertTrue(input.isPressed("Jump"))
    }

    /// A consuming context hides the maps beneath it, so Pause is hidden while the menu is open.
    func testConsumingContextHidesLowerMaps() {
        let input = makeInput()
        input.pushContext(InputSystem.Context("Gameplay", maps: ["Gameplay"]))
        runFrame(input, down(.escape))
        XCTAssertTrue(input.isPressed("Pause"))

        input.pushContext(InputSystem.Context("Menu", maps: ["UI"]))
        runFrame(input)
        XCTAssertFalse(input.isPressed("Pause"))
        XCTAssertTrue(input.isPressed("Cancel"))
        XCTAssertEqual(input.activeContextName, "Menu")
    }

    /// A non-consuming context leaves the maps beneath it active.
    func testNonConsumingContextKeepsLowerMapsActive() {
        let input = makeInput()
        input.pushContext(InputSystem.Context("Gameplay", maps: ["Gameplay"]))
        input.pushContext(InputSystem.Context("HUD", maps: [], consumes: false))
        runFrame(input, down(.space))
        XCTAssertTrue(input.isPressed("Jump"))
    }

    /// Popping a context restores the actions of the context beneath it.
    func testPopContextRestoresLowerContext() {
        let input = makeInput()
        input.pushContext(InputSystem.Context("Gameplay", maps: ["Gameplay"]))
        input.pushContext(InputSystem.Context("Menu", maps: ["UI"]))
        XCTAssertEqual(input.popContext()?.name, "Menu")
        runFrame(input, down(.escape))
        XCTAssertTrue(input.isPressed("Pause"))
    }

    /// A rebind captures the next key press, replaces the binding, and the old key no longer triggers the action.
    func testRebindCapturesNextKeyAndReplacesBinding() {
        let input = makeInput()
        var completions: [InputBinding?] = []
        input.beginRebind(action: "Jump", in: "Gameplay", bindingIndex: 0) { completions.append($0) }
        XCTAssertTrue(input.isRebinding)

        runFrame(input, down(.j))
        XCTAssertFalse(input.isRebinding)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0], InputBinding.key(.j))
        XCTAssertEqual(
            input.maps["Gameplay"]?.actions.first { $0.name == "Jump" }?.bindings.first, InputBinding.key(.j))

        runFrame(input, down(.space))
        XCTAssertFalse(input.isPressed("Jump"))
    }

    /// Escape cancels a pending rebind and reports nil to the completion.
    func testEscapeCancelsRebind() {
        let input = makeInput()
        var completions: [InputBinding?] = []
        input.beginRebind(action: "Jump", in: "Gameplay", bindingIndex: 0) { completions.append($0) }
        runFrame(input, down(.escape))
        XCTAssertFalse(input.isRebinding)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(completions[0])
    }

    /// Exported bindings re-import into a fresh system with identical maps.
    func testExportedBindingsRoundTrip() throws {
        let data = try makeInput().exportBindings()
        let restored = InputSystem()
        try restored.importBindings(data)
        XCTAssertEqual(restored.maps["Gameplay"], ActionMap.defaultGameplay)
        XCTAssertEqual(restored.maps["UI"], ActionMap.defaultUI)
    }

    /// The dead zone removes small deflections and rescales the remaining range to full output.
    func testDeadZoneRescalesOutsideInnerRadius() {
        let deadZone = DeadZone()
        XCTAssertEqual(deadZone.apply(Vec2(0.1, 0)).length, 0, accuracy: 1e-6)
        XCTAssertEqual(deadZone.apply(Vec2(1, 0)).x, 1, accuracy: 1e-5)
        XCTAssertEqual(deadZone.apply(Vec2(0.55, 0)).x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(deadZone.apply(Float(-0.55)), -0.5, accuracy: 1e-4)
    }
}
