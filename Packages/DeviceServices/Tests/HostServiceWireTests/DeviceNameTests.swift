import Testing

@testable import HostServiceWire

/// A device's name that reads with another extension than its own is shown and saved with its controls visible.
struct DeviceNameTests {
    @Test func controlsAreVisible() {
        #expect(DeviceName.visible("photo\u{202E}gpj.zip") == "photo[U+202E]gpj.zip")
        #expect(DeviceName.visible("a\u{2066}b\u{2069}\u{200F}\u{061C}") == "a[U+2066]b[U+2069][U+200F][U+061C]")
        #expect(DeviceName.visible("line\nbreak\u{7}\u{85}") == "line[U+000A]break[U+0007][U+0085]")
        for plain in ["IMG_0001.JPG", "Résumé.pdf", "שלום.txt", "👨‍👩‍👧.png", "[U+202E]"] {
            #expect(DeviceName.visible(plain) == plain)
        }
    }
}
