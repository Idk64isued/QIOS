import AVFoundation
import GameController
import MediaPlayer
import Photos
import SwiftUI
import UIKit

// Hardware-keyboard capture, iPhone volume buttons -> emulated volume, and screenshot saving.
//
// Keyboard: a zero-sized UITextField kept as the first responder while the device runs; keyPresses(_:with:) catches
// keys before UIKit swallows them and hands each one to the guest agent's `type` / `backspace`.
//
// Volume: an off-screen MPVolumeView lets the app read and set the system volume. On every change we send a +/-
// button press to the emulator, then roll the system level back to where it was so iPhone volume stays put.
//
// Screenshot: the newest guest frame as a PNG, saved into Photos (Halcyon album).

// MARK: - Hardware keyboard

/// A hidden text field that catches hardware-keyboard keys. Add it to the view hierarchy, call becomeFirstResponder,
/// and set `onKey`/`onDelete`/`onReturn`/`onTab` to react.
/// Whether the emulated USB keyboard is plugged in (nil: not tried yet), and the disconnect observer that unplugs it.
final class KeyboardAttachment {
    var attached: Bool?
    var observer: NSObjectProtocol?
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

final class KeyboardBridge: UITextField, UITextFieldDelegate {
    var attachment: KeyboardAttachment?
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: .zero)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardType = .asciiCapable
        // Off-screen; a real keyboard can still deliver keys even with an empty field as first responder.
        alpha = 0
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    // Only hardware keys; the software keyboard would block the display behind it. Returning an empty view makes
    // the software keyboard not appear for this field.
    override var inputView: UIView? {
        get { UIView() }
        set { _ = newValue }
    }

    // Replace cancels first so a BACKSPACE beep isn't heard; shouldChangeCharactersIn delivers the text.
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String)
        -> Bool
    {
        if string.isEmpty {
            onBackspace?()
        } else {
            onText?(string)
        }
        // The field itself stays empty; otherwise it grows forever.
        textField.text = ""
        return false
    }

    // Capture the Return key even when the system would otherwise consume it.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onText?("\n")
        return false
    }

    /// Raw keys: on the boards with a USB host (iPad, iPhone 4, iPod touch 4G) the emulator attaches a USB keyboard
    /// and takes key presses as they are, arrows, Escape and modifiers included. Returns false where it can't, and
    /// the press goes on to the text path above (the agent's `type`).
    var onRawKey: ((Int32, Bool) -> Bool)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = route(presses, down: true)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = route(presses, down: false)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = route(presses, down: false)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// The presses the raw path didn't take.
    private func route(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        guard let onRawKey else { return presses }
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, let code = MacKeyCode.from(hid: key.keyCode.rawValue), onRawKey(code, down) { continue }
            rest.insert(press)
        }
        return rest
    }
}

/// HID usage (UIKey.keyCode) to macOS virtual key code (kVK_*), which qemu_ios_ui_key_mac takes.
enum MacKeyCode {
    private static let letters: [Int32] = [
        0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,  // a-m
        0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06,  // n-z
    ]
    private static let digits: [Int32] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]  // 1-9, 0
    private static let others: [Int: Int32] = [
        0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31,             // return escape delete tab space
        0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E, 0x31: 0x2A,             // - = [ ] \
        0x33: 0x29, 0x34: 0x27, 0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C, // ; ' ` , . /
        0x39: 0x39, 0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79, // caps home pgup fwd-del end pgdn
        0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,                         // right left down up
        0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37,                         // left ctrl shift option command
        0xE4: 0x3E, 0xE5: 0x3C, 0xE6: 0x3D, 0xE7: 0x36,                         // right ctrl shift option command
    ]

    static func from(hid: Int) -> Int32? {
        if (0x04...0x1D).contains(hid) { return letters[hid - 0x04] }
        if (0x1E...0x27).contains(hid) { return digits[hid - 0x1E] }
        return others[hid]
    }
}

struct KeyboardBridgeView: UIViewRepresentable {
    let agent: GuestAgent?
    var qemu: QemuRuntime? = nil
    /// A reference to the created view, so other parts of the screen can call becomeFirstResponder on it.
    let bridgeRef: (KeyboardBridge?) -> Void

    func makeUIView(context: Context) -> KeyboardBridge {
        let field = KeyboardBridge()
        field.onText = { [weak field] text in
            guard let agent else { return }
            Task { @MainActor in await agent.typeText(text) }
            _ = field  // silence the capture warning
        }
        field.onBackspace = {
            guard let agent else { return }
            Task { @MainActor in await agent.backspace() }
        }
        // The emulated USB keyboard is plugged in on the first key press, only on machines that have one, and
        // unplugged when the phone's keyboard disconnects: while one is plugged in, iOS 4 shows no on-screen keyboard.
        let state = KeyboardAttachment()
        field.onRawKey = { [qemu] code, down in
            guard UserDefaults.standard.object(forKey: "rawKeyboard") as? Bool ?? true,
                let qemu, let keyMac = qemu.keyMac, let attach = qemu.hardwareKeyboard
            else { return false }
            if state.attached == nil {
                state.attached = attach(true)
                LTMLog.note("keyboard: " + (state.attached == true ? "USB keyboard attached, keys go straight to the device" : "no USB host on this machine; typing through the agent"))
            }
            guard state.attached == true else { return false }
            keyMac(code, down)
            return true
        }
        state.observer = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [qemu] _ in
            guard state.attached == true else { return }
            _ = qemu?.hardwareKeyboard?(false)
            state.attached = nil
            LTMLog.note("keyboard: unplugged; the device's on-screen keyboard is back")
        }
        field.attachment = state
        bridgeRef(field)
        return field
    }

    func updateUIView(_ view: KeyboardBridge, context: Context) {}

    static func dismantleUIView(_ view: KeyboardBridge, coordinator: Void) {
        view.resignFirstResponder()
    }
}

// MARK: - Hardware volume buttons -> guest

/// Watches the iPhone's volume slider and, when it moves, sends the matching guest button press, then puts the
/// system volume back where it was so the phone itself doesn't actually change.
@MainActor
final class VolumeWatcher: NSObject, ObservableObject {
    private let hidden = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    private var observation: NSKeyValueObservation?
    private var expected: Float?
    private var reverting = false
    /// What to do on a press: the host app wires these to Emulator.press(2) and press(3).
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?

    override init() {
        super.init()
        hidden.isHidden = true
        hidden.showsRouteButton = false
    }

    func start(in host: UIView) {
        guard observation == nil else { return }
        if hidden.superview == nil { host.addSubview(hidden) }
        AudioSessionSetup.apply()
        let session = AVAudioSession.sharedInstance()
        expected = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self, let new = change.newValue else { return }
            let old = change.oldValue ?? self.expected ?? new
            Task { @MainActor in self.handle(from: old, to: new) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        hidden.removeFromSuperview()
    }

    private func handle(from old: Float, to new: Float) {
        guard !reverting else { reverting = false; return }
        if new > old + 0.001 { onVolumeUp?() }
        if new < old - 0.001 { onVolumeDown?() }
        // Roll the system volume back to where it was (within a few hundred ms, before the HUD finishes animating).
        if let target = expected, abs(new - target) > 0.001 {
            setSystemVolume(target)
        }
    }

    /// MPVolumeView's slider is the only app-accessible way to set the system volume.
    private func setSystemVolume(_ value: Float) {
        guard let slider = hidden.subviews.compactMap({ $0 as? UISlider }).first else { return }
        reverting = true
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }
}

struct VolumeWatcherView: UIViewRepresentable {
    let watcher: VolumeWatcher
    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.isUserInteractionEnabled = false
        host.isHidden = true
        DispatchQueue.main.async { watcher.start(in: host) }
        return host
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: Void) {
        // The watcher outlives this view only if the caller keeps it; stop is idempotent.
    }
}

// MARK: - Screenshot the guest

enum Screenshot {
    enum Result {
        case saved
        case savedFile(URL)
        case noAccess
        case noFrame
        case failed(String)
    }

    /// Writes the newest frame to the app's temporary folder as a PNG; returns its URL.
    static func file(image: CGImage) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lighttouch-\(Int(Date().timeIntervalSince1970)).png")
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    /// Asks Photos for write access, then saves `image` into the Halcyon album (made if it isn't there).
    static func save(image: CGImage) async -> Result {
        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { return .noAccess }
        let album = await Self.album(named: "Halcyon")
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: pngData(image) ?? Data(), options: nil)
                if let album, let placeholder = request.placeholderForCreatedAsset,
                    let change = PHAssetCollectionChangeRequest(for: album)
                {
                    change.addAssets([placeholder] as NSArray)
                }
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Saves a recorded movie into the Halcyon album, as save(image:) does a screenshot.
    static func save(video url: URL) async -> Result {
        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { return .noAccess }
        let album = await Self.album(named: "Halcyon")
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
                if let album, let placeholder = request.placeholderForCreatedAsset,
                    let change = PHAssetCollectionChangeRequest(for: album)
                {
                    change.addAssets([placeholder] as NSArray)
                }
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func album(named name: String) async -> PHAssetCollection? {
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var found: PHAssetCollection?
        fetch.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == name {
                found = collection
                stop.pointee = true
            }
        }
        if let found { return found }
        var placeholder: PHObjectPlaceholder?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let change = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                placeholder = change.placeholderForCreatedAssetCollection
            }
        } catch {
            return nil
        }
        guard let placeholder else { return nil }
        let newly = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil)
        return newly.firstObject
    }
}
