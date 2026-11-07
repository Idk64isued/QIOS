import AppKit

final class SleepingAnimationView: NSView {
    private let animationLayer: CALayer

    init() {
        animationLayer = Self.loadAnimation() ?? CALayer()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        animationLayer.masksToBounds = false
        layer?.addSublayer(animationLayer)
    }

    /// The bundled Core Animation archive's root layer; nil (no animation) if the resource is missing or unreadable.
    private static func loadAnimation() -> CALayer? {
        guard let url = Bundle.main.url(forResource: "Sleeping", withExtension: "caar"),
            let data = try? Data(contentsOf: url),
            let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        let archive = unarchiver.decodeObject(forKey: "root") as? [String: Any]
        return archive?["rootLayer"] as? CALayer
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        animationLayer.frame = bounds
    }
}
