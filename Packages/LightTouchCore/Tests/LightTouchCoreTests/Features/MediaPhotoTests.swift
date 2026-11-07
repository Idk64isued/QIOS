import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import LightTouchCore

/// Photo preparation (MediaPhoto): upright by its EXIF orientation, at most 2048 px, a baseline JPEG, transparency
/// flattened on white, one identity for the same picture, malformed input refused and cancellation honored.
struct MediaPhotoTests {
    let red: MediaFixtures.RGBA = (220, 30, 30, 255), blue: MediaFixtures.RGBA = (30, 30, 220, 255)

    @Test func rotatedJPEGComesOutUprightAndBounded() async throws {
        try await withTemporaryState { work in
            // Landscape pixels, left half red, right half blue, shown rotated a quarter turn clockwise (EXIF 6).
            let source = work.appendingPathComponent("rotated.jpg")
            try MediaFixtures.image(
                source,
                width: 4096,
                height: 2048,
                type: .jpeg,
                orientation: 6,
                background: red,
                fill: [(CGRect(x: 2048, y: 0, width: 2048, height: 2048), blue)]
            )
            let image = try await prepareTwice(source)
            let pixels = try MediaFixtures.pixels(image)
            try #require(pixels.width == 1024 && pixels.height == 2048)
            #expect(!MediaFixtures.isProgressiveJPEG(image))
            #expect(pixels.at(512, 256).0 > 180, "the red half is on top")
            #expect(pixels.at(512, 1792).2 > 180, "the blue half at the bottom")
        }
    }

    @Test func transparencyBecomesWhite() async throws {
        try await withTemporaryState { work in
            let source = work.appendingPathComponent("alpha.png")
            try MediaFixtures.image(
                source,
                width: 300,
                height: 200,
                type: .png,
                fill: [(CGRect(x: 100, y: 50, width: 100, height: 100), red)]
            )
            let image = try await prepareTwice(source)
            let pixels = try MediaFixtures.pixels(image)
            try #require(pixels.width == 300 && pixels.height == 200)
            let corner = pixels.at(10, 10)
            #expect(min(corner.0, corner.1, corner.2) > 245, "the transparent area became white")
            #expect(pixels.at(150, 100).0 > 180)
        }
    }

    /// Prepares `source` twice: one identity, separate staging, the same bytes. Returns a copy of the image.
    func prepareTwice(_ source: URL) async throws -> URL {
        let photo = try await MediaPhoto.prepare(source)
        defer { try? FileManager.default.removeItem(at: photo.directory) }
        let repeated = try await MediaPhoto.prepare(source)
        defer { try? FileManager.default.removeItem(at: repeated.directory) }
        #expect(UUID(uuidString: photo.id) != nil)
        #expect(photo.id == repeated.id && photo.directory != repeated.directory)
        #expect(try Data(contentsOf: photo.image) == Data(contentsOf: repeated.image))
        let copy = source.appendingPathExtension("prepared.jpg")
        try FileManager.default.copyItem(at: photo.image, to: copy)
        return copy
    }

    @Test func malformedAndCancelled() async throws {
        try await withTemporaryState { work in
            let broken = work.appendingPathComponent("broken.png")
            try Data("not an image".utf8).write(to: broken)
            await #expect(throws: (any Error).self) { try await MediaPhoto.prepare(broken) }
            let alpha = work.appendingPathComponent("alpha.png")
            try MediaFixtures.image(alpha, width: 300, height: 200, type: .png, fill: [])
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await MediaPhoto.prepare(alpha)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }
}
