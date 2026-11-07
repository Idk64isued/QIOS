// The installed apps' icons as AppKit images, decoded once from AppMetadataCache's files (LightTouchCore).

import Cocoa
import LightTouchCore

extension AppMetadataCache {
    func icon(for bundleID: String) -> NSImage? {
        guard hasIcon(bundleID) else { return nil }
        if let memo = iconMemo.object(forKey: bundleID as NSString) as? NSImage { return memo }
        guard let image = NSImage(contentsOf: iconURL(bundleID)) else { return nil }
        iconMemo.setObject(image, forKey: bundleID as NSString)
        return image
    }
}
