import CoreGraphics
import Foundation
import Testing

@testable import LightTouchCore

/// A writer that writes "movie" at start and can fail where told (the encoder, a frame's audio).
private actor FakeWriter: ScreenMovieRecording {
    var starts = 0
    var failStartup = false
    var failFrame = 0
    private var output: URL?
    private var frames = 0

    func configure(failStartup: Bool? = nil, failFrame: Int? = nil) {
        if let failStartup { self.failStartup = failStartup }
        if let failFrame { self.failFrame = failFrame }
    }

    func start(url: URL, audio: GuestAudioCapture?, canvasSize: CGSize?, background: CGImage?, screenSize: CGSize)
        async throws
    {
        starts += 1
        frames = 0
        try await Task.sleep(for: .milliseconds(30))
        if failStartup { throw CaptureError.failed("Encoder unavailable") }
        output = url
        try Data("movie".utf8).write(to: url)
    }
    func append(_ image: CGImage?, seconds: Double) async throws {
        frames += 1
        if frames == failFrame { throw CaptureError.failed("Audio buffer overflow") }
    }
    func finish(seconds: Double) async throws {
        #expect(frames > 0 && seconds > 0)
        output = nil
    }
    func cancel() async {
        if let output { try? FileManager.default.removeItem(at: output) }
        output = nil
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ltm-tests-" + UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.resolvingSymlinksInPath()
}

/// Polls the main actor until `check` holds; the deadline only guards a hang.
private func wait(_ check: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !check(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(check(), "timed out")
}

/// A recording's lifecycle (sounds, atomic saves, the fallback picker, typed outcomes, explicit discard); a take that
/// can't be saved is kept where it was written.
struct ScreenRecordingSessionTests {
    let thumbnail = CGContext(
        data: nil,
        width: 16,
        height: 24,
        bitsPerComponent: 8,
        bytesPerRow: 64,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!.makeImage()!

    @Test func lifecycleSoundsSavesAndKeptTakes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FakeWriter()
        let folder = root.appendingPathComponent("Recordings")
        let session = ScreenRecordingSession(writer: writer, folder: folder)
        var cues: [String] = []
        var completions: [Bool] = []
        var outcomes: [ScreenRecordingSession.Completion] = []
        session.onCompleted = { outcomes.append($0) }
        session.onBeganRecording = { cues.append("start") }
        session.onStoppedRecording = { cues.append("stop") }
        session.onFinished = { completions.append($0) }
        let output = root.appendingPathComponent("saved.mov")
        let thumbnail = thumbnail
        session.start(frame: { thumbnail }, destination: { output })
        session.start(
            frame: { nil },
            destination: {
                Issue.record("duplicate start")
                return output
            }
        )
        session.stop()
        #expect(session.phase == .saving)
        try await wait { !session.isActive }
        #expect(session.phase == .saved(output) && completions == [true])
        #expect(cues.isEmpty, "a take stopped during startup must not play success sounds")
        #expect(session.previewImage === thumbnail, "saved recording lost its thumbnail")
        #expect(try Data(contentsOf: output) == Data("movie".utf8))

        session.start(
            frame: { nil },
            destination: {
                Issue.record("discard must not save")
                return output
            }
        )
        #expect(session.previewImage == nil, "a new recording retained the previous thumbnail")
        session.stop(discard: true)
        try await wait { !session.isActive }
        #expect(session.phase == .idle && completions == [true, true])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        // An existing destination must survive an automatic save collision.
        session.start(frame: { nil }, destination: { output })
        try await wait { session.phase == .recording }
        #expect(cues == ["start"])
        session.stop()
        session.stop()
        #expect(cues == ["start", "stop"], "stop must play once, including repeated stop requests")
        try await wait { !session.isActive }
        guard case .failed(let kept?) = outcomes.last else {
            Issue.record("the unsaved take wasn't kept: \(outcomes)")
            return
        }
        #expect(session.phase == .idle && completions.last == false)
        #expect(try Data(contentsOf: kept) == Data("movie".utf8), "the take stays where it was written")
        #expect(try Data(contentsOf: output) == Data("movie".utf8), "and the existing file is untouched")

        // A writer failure keeps the partial take too, and the next take still starts.
        await writer.configure(failFrame: 3)
        session.start(frame: { nil }, destination: { output })
        try await wait { !session.isActive }
        guard case .failed(let partial?) = outcomes.last else {
            Issue.record("lost partial movie")
            return
        }
        #expect(partial != kept && FileManager.default.fileExists(atPath: partial.path))
        #expect(session.failure?.localizedDescription == "Audio buffer overflow")
        #expect(cues == ["start", "stop", "start", "stop"], "an interrupted take must finish its sound pair")
        session.dismiss()

        await writer.configure(failStartup: true, failFrame: 0)
        session.start(frame: { nil }, destination: { output })
        session.stop()
        try await wait { !session.isActive }
        #expect(session.phase == .idle && session.failure?.localizedDescription == "Encoder unavailable")
        #expect(cues == ["start", "stop", "start", "stop"], "failed startup must not play recording cues")
    }

    /// A preferred-folder failure opens one save panel while the take remains busy, without announcing failure first;
    /// cancelling keeps the sole copy; discard is explicit; an invalid choice doesn't loop the picker.
    @Test func fallbackPicker() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = ScreenRecordingSession(writer: FakeWriter(), folder: root.appendingPathComponent("Recordings"))
        var outcomes: [ScreenRecordingSession.Completion] = []
        fallback.onCompleted = { outcomes.append($0) }
        let output = root.appendingPathComponent("saved.mov")
        let alternate = root.appendingPathComponent("alternate.mov")
        try Data("existing".utf8).write(to: output)
        try Data("replace me".utf8).write(to: alternate)
        var panels = 0
        fallback.chooseSaveDestination = { _ in
            #expect(fallback.phase == .saving && outcomes.isEmpty)
            panels += 1
            return alternate
        }
        let thumbnail = thumbnail
        fallback.start(frame: { thumbnail }, destination: { output })
        fallback.stop()
        try await wait { !fallback.isActive }
        #expect(fallback.phase == .saved(alternate) && outcomes == [.saved(alternate)] && panels == 1)
        #expect(fallback.failure == nil)
        #expect(try Data(contentsOf: alternate) == Data("movie".utf8))
        #expect(try Data(contentsOf: output) == Data("existing".utf8), "an automatic save never replaces a file")

        fallback.chooseSaveDestination = { _ in
            panels += 1
            return nil
        }
        fallback.start(frame: { thumbnail }, destination: { throw CaptureError.failed("Folder unavailable") })
        fallback.stop()
        try await wait { !fallback.isActive }
        guard case .failed(let cancelledSave?) = outcomes.last else {
            Issue.record("panel cancellation lost the take: \(outcomes)")
            return
        }
        #expect(panels == 2 && fallback.phase == .idle && FileManager.default.fileExists(atPath: cancelledSave.path))

        fallback.chooseSaveDestination = { _ in
            panels += 1
            return root.appendingPathComponent("missing/fallback.mov")
        }
        fallback.start(frame: { thumbnail }, destination: { output })
        fallback.stop()
        try await wait { !fallback.isActive }
        guard case .failed(let failedSave?) = outcomes.last else {
            Issue.record("failed fallback lost the take")
            return
        }
        #expect(panels == 3 && failedSave != cancelledSave && FileManager.default.fileExists(atPath: failedSave.path))
    }
}
