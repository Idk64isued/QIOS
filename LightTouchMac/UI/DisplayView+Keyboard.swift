import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    // MARK: - Keyboard pointer (typing disabled)

    func send(_ touch: KeyboardPointer.Touch?) {
        guard let touch else { return }
        let phase =
            switch touch.phase {
            case .begin: TouchPhase.begin
            case .update: TouchPhase.update
            case .end: TouchPhase.end
            }
        sendVisualTouch(0, phase, touch.point.x, touch.point.y, keyboard: true)
    }

    func endKeyboardTouch() { send(keyboardPointer.end()) }

    /// Tab out of the screen (KeyboardPointer.focusMove).
    private func moveFocusOut(_ event: NSEvent) -> Bool {
        switch KeyboardPointer.focusMove(
            keyCode: event.keyCode,
            modifiers: KeyModifiers(event.modifierFlags),
            typingOff: emulator?.keyboardInputEnabled == false
        ) {
        case .next?: window?.selectNextKeyView(self)
        case .previous?: window?.selectPreviousKeyView(self)
        case nil: return false
        }
        return true
    }

    private func keyboardPointerKey(_ event: NSEvent, down: Bool) -> Bool {
        let (handled, touches) = keyboardPointer.key(
            event.keyCode,
            down: down,
            modifiers: KeyModifiers(event.modifierFlags),
            typingOff: emulator?.keyboardInputEnabled == false,
            canTouch: touchInteractionEnabled && !touchDown && !pinchingGuest && scrollPoint == nil
        )
        touches.forEach(send)
        return handled
    }

    func updateKeyboardPointer() {
        let active =
            touchInteractionEnabled && emulator?.keyboardInputEnabled == false && window?.isKeyWindow == true
            && window?.firstResponder === self
        if !active { endKeyboardTouch() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hidden = !active || !keyboardPointer.isShown
        if keyboardPointerLayer.isHidden != hidden { keyboardPointerLayer.isHidden = hidden }
        if active { keyboardPointerLayer.position = projectedPanelPoint(keyboardPointer.point) }
        CATransaction.commit()
    }

    // MARK: - Keyboard passthrough
    override func keyDown(with event: NSEvent) {
        emulator?.userInteracted()
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            consumedWakeSpace || (emulator?.isSleeping == true && emulator?.acceptsInput == true)
        {
            if !consumedWakeSpace && !event.isARepeat { emulator?.pressLock() }
            consumedWakeSpace = true
            return
        }
        if isShowingLiveText {
            if event.keyCode == 53 { endLiveText() } else { super.keyDown(with: event) }
            return
        }
        if moveFocusOut(event) { return }
        if panelKey(event) { return }
        // Command combinations belong to the menu bar; let them pass.
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyDown(with: event)
            return
        }
        if keyboardPointerKey(event, down: true) { return }
        if !hasMarkedText(),
            GuestKeyboard.passesThrough(
                keyCode: event.keyCode,
                characters: event.characters,
                shift: event.modifierFlags.contains(.shift),
                inputSource: inputContext?.selectedKeyboardInputSource
            )
        {
            pressKey(event.keyCode)
        } else {
            // Another layout, a dead key or an input method: the text input system composes, insertText sends.
            keyInText = event
            inputContext?.handleEvent(event)
            keyInText = nil
        }
    }

    // MARK: - Held keys and composed text

    private func pressKey(_ code: UInt16) {
        heldKeys.press(code)
        emulator?.sendKey(macKeyCode: code, down: true)
    }

    /// Focus left the screen (another view, window or app): every key the guest has down goes up.
    @objc func releaseHeldKeys() {
        for code in heldKeys.releaseAll() { emulator?.sendKey(macKeyCode: code, down: false) }
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 && consumedWakeSpace {
            consumedWakeSpace = false
            return
        }
        if !keyboardPointer.touchKeys.isEmpty, keyboardPointerKey(event, down: false) { return }
        if isShowingLiveText { return }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyUp(with: event)
            return
        }
        if keyboardPointerKey(event, down: false) { return }
        if heldKeys.release(event.keyCode) { emulator?.sendKey(macKeyCode: event.keyCode, down: false) }
    }

    override func flagsChanged(with event: NSEvent) {
        // Shift and Option only ever arrive here, never as keyDown, so the
        // guest keyboard missed them (no capitals, no "!"). Command and
        // Control stay with the menu bar. sendKey lets key-ups through while
        // input is off, so a modifier can't stick down.
        let down: Bool?
        switch event.keyCode {
        case 56, 60: down = event.modifierFlags.contains(.shift)
        case 58, 61: down = event.modifierFlags.contains(.option)
        default: down = nil
        }
        if let down {
            if down { heldKeys.press(event.keyCode) } else { _ = heldKeys.release(event.keyCode) }
            emulator?.sendKey(macKeyCode: event.keyCode, down: down)
        }
        updatePairRings(event.modifierFlags)
        send(keyboardPointer.modifiersChanged(KeyModifiers(event.modifierFlags)))
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldKeys()
        endKeyboardTouch()
        resetMotion()
        return super.resignFirstResponder()
    }
}

// Composed text (input methods, dead keys, other layouts) reaches the guest as text: EmulatorController.typeText.
// The composition itself isn't drawn here; the input method's own window shows it beside the screen.
extension DisplayView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        markedText = NSMutableAttributedString()
        emulator?.typeText(text, shiftHeld: heldKeys.down.contains(56) || heldKeys.down.contains(60))
    }
    /// A key the input system didn't turn into text (Return or an arrow with nothing composed): as itself.
    override func doCommand(by selector: Selector) {
        if let keyInText { pressKey(keyInText.keyCode) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = NSMutableAttributedString(
            attributedString: (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        )
    }
    func unmarkText() { markedText = NSMutableAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: markedText.length, length: 0) }
    func markedRange() -> NSRange {
        markedText.length > 0
            ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let clipped = Range(range, in: markedText.string).map({ NSRange($0, in: markedText.string) }) else {
            return nil
        }
        actualRange?.pointee = clipped
        return markedText.attributedSubstring(from: clipped)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    /// The candidate window sits under the screen's lower middle.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let anchor = NSRect(x: bounds.midX, y: bounds.minY + bounds.height * 0.25, width: 1, height: 20)
        return window?.convertToScreen(convert(anchor, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
