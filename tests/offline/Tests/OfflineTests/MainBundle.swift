import Foundation
import ObjectiveC

/// The app bundle's resources for code that looks them up in Bundle.main (DisplayView's Models/<board>.usdz, the
/// shell art by name): a throwaway .app holding links to the repository's files stands in as the main bundle while
/// `body` runs. Tests run one at a time (SharedState), so nothing else sees it.
enum MainBundle {
    static let repository = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// `resources`: path under Contents/Resources -> path in the repository.
    static func with<T>(_ resources: [String: String], _ body: @MainActor () async throws -> T) async throws -> T {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-check-\(UUID().uuidString).app")
        let contents = app.appendingPathComponent("Contents")
        defer { try? FileManager.default.removeItem(at: app) }
        for (name, source) in resources {
            let link = contents.appendingPathComponent("Resources/" + name)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: repository.appendingPathComponent(source)
            )
        }
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "app.lighttouch.check", "CFBundlePackageType": "APPL"],
            format: .xml,
            options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = Bundle(url: app)!
        let method = class_getClassMethod(Bundle.self, #selector(getter: Bundle.main))!
        let block: @convention(block) (AnyObject) -> Bundle = { _ in bundle }
        let replacement = imp_implementationWithBlock(block)
        let previous = method_setImplementation(method, replacement)
        defer {
            method_setImplementation(method, previous)
            imp_removeBlock(replacement)
        }
        return try await body()
    }
}
