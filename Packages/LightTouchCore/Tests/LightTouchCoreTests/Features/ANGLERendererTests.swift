import Foundation
import Testing

@testable import LightTouchCore

/// Settings ▸ General ▸ ANGLE renderer: off until it is turned on.
@Suite(.serialized) struct ANGLERendererTests {
    @Test func offUntilTurnedOn() {
        let saved = UserDefaults.standard.object(forKey: ANGLERenderer.key)
        defer { UserDefaults.standard.set(saved, forKey: ANGLERenderer.key) }
        UserDefaults.standard.removeObject(forKey: ANGLERenderer.key)
        #expect(!ANGLERenderer.isOn)
        UserDefaults.standard.set(true, forKey: ANGLERenderer.key)
        #expect(ANGLERenderer.isOn)
    }
}
