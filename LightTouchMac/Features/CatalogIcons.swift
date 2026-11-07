// The Store rows' AppKit side of the Legacy Store client (LightTouchCore's CatalogClient): the
// catalog row's drag type and its icons.

import Cocoa
import LightTouchCore

extension NSPasteboard.PasteboardType {
    /// A JSON-encoded CatalogApp riding a drag out of the Store list, so the
    /// device view can offer drag-to-install for catalog rows.
    static let ltmCatalogApp = NSPasteboard.PasteboardType("app.lighttouch.catalog-app")
}

extension CatalogClient {
    /// One shared memo for catalog row icons; they're 57–512 px PNGs keyed by
    /// their content-addressed URL, so entries never go stale.
    static let iconMemo = NSCache<NSString, NSImage>()

    static func icon(for app: CatalogApp) async -> NSImage? {
        guard let url = app.iconURL else { return nil }
        if let memo = iconMemo.object(forKey: url.absoluteString as NSString) { return memo }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let image = NSImage(data: data)
        else { return nil }
        iconMemo.setObject(image, forKey: url.absoluteString as NSString)
        return image
    }
}
