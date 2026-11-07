import Foundation

/// `swift run … sessions` builds the sessions product alone, so session-driver and helper-driver beside it could be
/// from an older build and run old code; sessions brings each driver up to date before it starts it.
public enum DriverBuild {
    /// The `swift build` arguments that bring `product` in `bin` up to date with the sources, when `bin` is
    /// `package`'s own build output (in the configuration it names: Debug, Release); nil for a copy elsewhere.
    public static func arguments(product: String, bin: URL, package: URL) -> [String]? {
        let build = package.appendingPathComponent(".build").resolvingSymlinksInPath().path + "/"
        guard bin.resolvingSymlinksInPath().path.hasPrefix(build) else { return nil }
        let release = bin.lastPathComponent.lowercased() == "release"
        return ["build", "--package-path", package.path, "--product", product] + (release ? ["-c", "release"] : [])
    }
}
