import CoreGraphics
import Foundation

/// What a recording session writes its take with: ScreenMovieWriter.
nonisolated public protocol ScreenMovieRecording: AnyObject, Sendable {
    func start(url: URL, audio: GuestAudioCapture?, canvasSize: CGSize?, background: CGImage?, screenSize: CGSize)
        async throws
    func append(_ image: CGImage?, seconds: Double) async throws
    func finish(seconds: Double) async throws
    func cancel() async
}

extension ScreenMovieWriter: ScreenMovieRecording {}

/// Owns one recording from its first frame through a durable save. A take that can't be saved (the destination
/// failed and the save panel was cancelled, or the writer failed) stays in recordingsDirectory, and the completion
/// names it.
@MainActor
public final class ScreenRecordingSession {
    public enum Phase: Equatable {
        case idle, starting, recording, saving
        case saved(URL)
    }
    public enum Completion: Equatable {
        case saved(URL)
        case discarded
        /// `kept`: the unsaved take, left where it was written.
        case failed(kept: URL?)
    }

    public private(set) var phase: Phase = .idle {
        didSet {
            activity.held = isActive
            onChange?()
        }
    }
    private var activity = UserActivity("Recording a device's screen")
    public private(set) var elapsedSeconds = 0
    public private(set) var failure: Error?
    public private(set) var previewImage: CGImage?
    public var onChange: (() -> Void)?
    public var onFinished: ((Bool) -> Void)?
    public var onCompleted: ((Completion) -> Void)?
    /// A failed preferred location falls back to a per-file save panel. The
    /// completed source remains durable if the panel is cancelled or fails.
    public var chooseSaveDestination: ((Error) async -> URL?)?
    public var onBeganRecording: (() -> Void)?
    public var onStoppedRecording: (() -> Void)?
    private var didBeginRecording = false
    private let writer: any ScreenMovieRecording
    /// Where takes are written until they're saved (recordingsDirectory).
    private let folder: URL

    /// `folder`: recordingsDirectory unless given.
    public init(writer: any ScreenMovieRecording = ScreenMovieWriter(), folder: URL? = nil) {
        self.writer = writer
        self.folder = folder ?? Self.recordingsDirectory
    }
    private var producer: Task<Void, Never>?
    private var output: URL?
    private var startedAt: TimeInterval = 0
    private var writerStarted = false
    public private(set) var id = UUID()
    private var stopRequested = false
    private var discardRequested = false
    private var destination: (() throws -> URL)?

    public var isActive: Bool { phase == .starting || phase == .recording || phase == .saving }
    public var canStop: Bool { phase == .starting || phase == .recording }
    public var elapsed: String {
        let seconds = elapsedSeconds % 60
        let minutes = (elapsedSeconds / 60) % 60
        let hours = elapsedSeconds / 3600
        let tail = "\(seconds < 10 ? "0" : "")\(seconds)"
        return hours > 0
            ? "\(hours):\(minutes < 10 ? "0" : "")\(minutes):\(tail)"
            : "\(minutes):\(tail)"
    }
    public static var recordingsDirectory: URL {
        Bundled.stateDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Recordings/ is out of backups while a take is being written into it
    /// (a large, changing file), and back in once it's idle.
    private func excludeRecordingsFromBackup(_ excluded: Bool) {
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? folder.setResourceValues(values)
    }

    /// `audio` starts the device's guest audio capture (nil: a silent movie).
    public func start(
        frame: @escaping () throws -> CGImage?,
        audio: @escaping () async throws -> GuestAudioCapture? = { nil },
        prepare: @escaping () async throws -> CGSize? = { nil },
        cleanup: @escaping () async -> Void = {},
        background: CGImage? = nil,
        screenSize: CGSize = CGSize(width: 320, height: 480),
        destination: @escaping () throws -> URL
    ) {
        guard !isActive else { return }
        begin(
            frame: frame,
            audio: audio,
            prepare: prepare,
            cleanup: cleanup,
            background: background,
            screenSize: screenSize,
            destination: destination
        )
    }

    private func begin(
        frame: @escaping () throws -> CGImage?,
        audio: @escaping () async throws -> GuestAudioCapture?,
        prepare: @escaping () async throws -> CGSize?,
        cleanup: @escaping () async -> Void,
        background: CGImage?,
        screenSize: CGSize,
        destination: @escaping () throws -> URL
    ) {
        failure = nil
        previewImage = nil
        id = UUID()
        writerStarted = false
        didBeginRecording = false
        elapsedSeconds = 0
        stopRequested = false
        discardRequested = false
        self.destination = destination
        phase = .starting
        producer = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                excludeRecordingsFromBackup(true)
                let url = folder.appendingPathComponent("Recording \(UUID().uuidString).mov")
                output = url
                let canvasSize = try await prepare()
                let capture = try await audio()
                do {
                    try await writer.start(
                        url: url,
                        audio: capture,
                        canvasSize: canvasSize,
                        background: background,
                        screenSize: screenSize
                    )
                } catch {
                    capture?.stop()
                    throw error
                }
                writerStarted = true
                startedAt = ProcessInfo.processInfo.systemUptime
                // A stop during startup still produces a playable first frame.
                let firstFrame = try frame()
                previewImage = firstFrame
                try await writer.append(firstFrame, seconds: 0)
                if !stopRequested {
                    phase = .recording
                    didBeginRecording = true
                    onBeganRecording?()
                }
                while !stopRequested {
                    try await Task.sleep(for: .milliseconds(canvasSize == nil ? 33 : 16))
                    guard !stopRequested else { break }
                    try await writer.append(try frame(), seconds: ProcessInfo.processInfo.systemUptime - startedAt)
                    let seconds = Int(ProcessInfo.processInfo.systemUptime - startedAt)
                    if elapsedSeconds != seconds {
                        elapsedSeconds = seconds
                        onChange?()
                    }
                }
            } catch {
                failure = error
                stopRequested = true
            }
            await cleanup()
            await complete()
        }
    }

    public func stop(discard: Bool = false) {
        guard canStop else { return }
        if didBeginRecording {
            didBeginRecording = false
            onStoppedRecording?()
        }
        discardRequested = discard
        stopRequested = true
        phase = .saving
    }

    private func complete() async {
        defer { excludeRecordingsFromBackup(false) }
        // Also announce an interrupted take, once, if frames had started.
        if didBeginRecording {
            didBeginRecording = false
            onStoppedRecording?()
        }
        phase = .saving
        if discardRequested {
            await writer.cancel()
            discardOutput()
            return
        }
        do {
            if let failure {
                // An audio-source error can leave valid video in a healthy
                // writer. Finalize that partial take before keeping it.
                if writerStarted {
                    try? await writer.finish(seconds: max(ProcessInfo.processInfo.systemUptime - startedAt, 0.034))
                }
                await writer.cancel()
                throw failure
            }
            try await writer.finish(seconds: max(ProcessInfo.processInfo.systemUptime - startedAt, 0.034))
            guard let output, let destination else { throw CaptureError.failed("No recording file is available.") }
            let saved: URL
            do {
                let preferred = try destination()
                try await Self.save(output, to: preferred)
                saved = preferred
            } catch {
                guard let chosen = await chooseSaveDestination?(error) else { throw error }
                // NSSavePanel obtained any replacement confirmation. Choosing
                // a file here does not change the preferred capture location.
                try await Self.save(output, to: chosen, replaceExisting: true)
                saved = chosen
            }
            self.output = nil
            failure = nil
            phase = .saved(saved)
            completed(.saved(saved))
        } catch {
            failure = error
            keepOutput()
        }
    }

    /// Ends a take that couldn't be saved or deleted: the file, if any, stays where it was written.
    private func keepOutput() {
        let kept = output.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        output = nil
        phase = .idle
        completed(.failed(kept: kept))
    }

    private func discardOutput() {
        do {
            if let output, FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            output = nil
            failure = nil
            previewImage = nil
            phase = .idle
            completed(.discarded)
        } catch {
            failure = error
            keepOutput()
        }
    }

    private func completed(_ result: Completion) {
        producer = nil
        onCompleted?(result)
        switch result {
        case .saved, .discarded: onFinished?(true)
        case .failed: onFinished?(false)
        }
    }

    public func dismiss() {
        guard !isActive else { return }
        output = nil
        failure = nil
        phase = .idle
    }

    @concurrent
    private static func save(_ source: URL, to destination: URL, replaceExisting: Bool = false) async throws {
        // Saving in place is already durable. Do not remove the destination
        // when the user chooses the take itself in the save panel.
        if source.resolvingSymlinksInPath().standardizedFileURL
            == destination.resolvingSymlinksInPath().standardizedFileURL
        {
            return
        }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".ltm-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        if replaceExisting, FileManager.default.fileExists(atPath: destination.path) {
            // NSSavePanel obtained the user's replacement decision.
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        try? FileManager.default.removeItem(at: source)
    }
}
