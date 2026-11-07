import BuildSupport
import Foundation
import Testing

@testable import ReleaseChecks

/// The repository this test file sits in.
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The app's tests run when an app was given or the Release plan requires one (then a missing app fails).
let appGiven = ReleaseApp.given || ReleaseApp.required

/// The release is built with the helper under the App Sandbox unless LTM_RELEASE_HELPER_SANDBOX=NO (scripts/ship passes
/// its LTM_HELPER_SANDBOX, YES by default): its helper and app must carry exactly that build's entitlements.
let helperSandbox = ProcessInfo.processInfo.environment["LTM_RELEASE_HELPER_SANDBOX"] != "NO"
