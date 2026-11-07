import AudioToolbox
import LightTouchCore

/// The system sounds for explicit capture actions: screenshot, recording started and stopped.
enum CaptureSound: SystemSoundID {
    case screenshot = 1393
    case recordingStarted = 1113
    case recordingStopped = 1114

    func play() {
        guard CapturePreferences.shared.soundEffectsEnabled else { return }
        AudioServicesPlaySystemSound(rawValue)
    }
}
