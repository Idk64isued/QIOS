import Foundation
import Testing

@testable import LightTouchCore

private let helpFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../../LightTouchMac/Help.txt").standardizedFileURL

/// The bundled Help.txt as task topics: the chosen topic's own text, [Device] read as the device's name, the HIG
/// audit's cuts and the menu paths that exist.
struct HelpTopicTests {
    let whole: String
    let topics: [HelpTopic]

    init() throws {
        whole = try String(contentsOf: helpFile, encoding: .utf8)
        topics = HelpTopic.topics(whole)
    }

    func shown(_ title: String, device: String = "iPad") throws -> String {
        let topic = try #require(topics.first { $0.title == title }, "no topic \(title)").naming(device)
        return topic.title + "\n" + topic.shownBody
    }

    @Test func taskTopicsInOrder() {
        let titles = topics.map(\.title)
        #expect(topics.count >= 10 && Set(titles).count == titles.count)
        #expect(titles.first == "Adding and starting devices" && titles.last == "Licenses", "\(titles)")
        #expect(topics.allSatisfy { !$0.body.isEmpty && !$0.body.contains("\n# ") })
    }

    @Test func aTopicLineStartsEachTopic() {
        let parsed = HelpTopic.topics("# One\nFirst line\n\nThen a # mid-line\n# Two\nSecond\n# Empty")
        #expect(
            parsed == [
                HelpTopic(title: "One", body: "First line\n\nThen a # mid-line"),
                HelpTopic(title: "Two", body: "Second"),
                HelpTopic(title: "Empty", body: "")
            ]
        )
    }

    /// Choosing a topic shows that topic, not the whole file.
    @Test func aTopicShowsItsOwnText() throws {
        let capture = try shown("Screenshots and recordings")
        #expect(
            capture.hasPrefix("Screenshots and recordings\n") && capture.contains("Recordings include device audio")
                && !capture.contains("Physical Size")
        )
        #expect(try shown("Rotating and zooming").contains("Physical Size"))
        #expect(
            try shown("Motion").contains("Natural Scrolling") && shown("Motion").contains("Rotate with two fingers")
        )
        #expect(
            !(try shown("Screenshots and recordings")).contains("\n\n"),
            "paragraphs are spaced by the view, not blank lines"
        )
    }

    @Test func deviceReadsAsTheDevicesName() throws {
        let files = try shown("Device files")
        #expect(
            files.contains("Show iPad Files") && files.contains("Copy to iPad") && !files.contains("[Device]"),
            "\(files)"
        )
        #expect(try shown("Device files", device: "iPod").contains("Show iPod Files"))
    }

    /// The audit's cuts, and menu paths that moved: none may come back.
    @Test(arguments: [
        "stands for", "It is unavailable when measurements", "The pointer stops interacting", "Refresh Apps refreshes",
        "share the inspector’s queue", "starts when the device is free", "The Apps inspector opens", "converts raw AAC",
        "stay out of captures", "offers Discard, Stop and Save", "cancelling keeps", "dismisses its notification",
        "old saved city", "moon", "Successful retries", "inspect the boot", "Updates pause while", "displayed tail",
        "Controller release", "Device → Orientation", "Help → Device Logs", "Help → Show Unfinished",
        "Capture → Capture Options", "⌘O", "Edit → Search Apps", "Local Network", "Device Logs button",
        "next app launch"
    ])
    func cutTextStaysOut(_ gone: String) {
        #expect(!whole.contains(gone), "Help still says: \(gone)")
    }

    @Test(arguments: [
        "File → Add Device (⌘N)", "Window → Device Logs",
        "Light Touch → Settings → Capture", "Device → Motion"
    ])
    func currentMenuPaths(_ path: String) {
        #expect(whole.contains(path), "Help lacks \(path)")
    }
}
