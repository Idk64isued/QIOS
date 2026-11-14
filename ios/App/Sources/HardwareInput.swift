import AVFoundation
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
// Screenshot: the newest guest frame as a PNG, saved into Photos (Light Touch album).

// MARK: - Hardware keyboard

/// A hidden text field that catches hardware-keyboard keys. Add it to the view hierarchy, call becomeFirstResponder,
/// and set `onKey`/`onDelete`/`onReturn`/`onTab` to react.
final class KeyboardBridge: UITextField, UITextFieldDelegate {
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
}

struct KeyboardBridgeView: UIViewRepresentable {
    let agent: GuestAgent?
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
final class VolumeWatcher: NSObject {
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
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            LTMLog.note("volume: audio session not active: \(error.localizedDescription)")
        }
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

    /// Asks Photos for write access, then saves `image` into the Light Touch album (made if it isn't there).
    static func save(image: CGImage) async -> Result {
        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { return .noAccess }
        let album = await Self.album(named: "Light Touch")
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
