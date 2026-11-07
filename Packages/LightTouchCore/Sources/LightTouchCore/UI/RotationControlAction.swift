/// The normal button returns landscape to portrait, or turns portrait left.
/// Option reverses that next quarter-turn without changing the menu commands.
public struct RotationControlAction {
    public let clockwise: Bool

    public init(rotationDegrees: Int, optionPressed: Bool) {
        clockwise = (rotationDegrees == 270) != optionPressed
    }

    public var title: String { clockwise ? "Rotate Right" : "Rotate Left" }
    public var symbol: String { clockwise ? "rotate.right" : "rotate.left" }
    public var help: String { title + (clockwise ? " (Option rotates left)" : " (Option rotates right)") }
}
