@preconcurrency import AVFoundation
import CallKit

/// The camera's sound (D20, D21). The camera never needs the microphone to
/// run: it's only for videos' sound. Left to itself, a capture session with
/// the microphone in sets up the app's audio on its own, in a way that stops
/// music, and on a phone call (whose microphone it is) iOS interrupts the
/// whole session, picture and all. So napsack sets up its audio itself,
/// mixed with whatever else is playing, only while the camera is open; it
/// takes the microphone only when nothing else has it; and if it's
/// interrupted for it anyway, it lets it go and carries on. A video taken
/// without it has no sound, and says so. These are the decisions; the camera
/// (CameraSession) carries them out.
enum CameraAudio {
    /// How the app's audio is set.
    struct Setting: Equatable, @unchecked Sendable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    /// While the camera is open with the microphone: recording and playing,
    /// mixed with others (music keeps on, through a pic or a video), out of the
    /// speaker rather than the earpiece, and to Bluetooth headphones. The plain
    /// mode: the video-recording one is for apps that are the only sound.
    static let whileOpen = Setting(category: .playAndRecord, mode: .default,
                                   options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])

    /// Whether the camera takes the microphone, as it opens or as a video
    /// starts: only when you've allowed it, no call has it, and the phone has
    /// an input to give.
    static func takesMicrophone(allowed: Bool, onCall: Bool, inputAvailable: Bool) -> Bool {
        allowed && !onCall && inputAvailable
    }

    /// What an interruption of the capture session calls for.
    enum Response: Equatable, Sendable {
        /// Something else took the microphone (a call): let it go and carry on without.
        case dropMicrophone
        /// Anything else (the app going to the background, another app's
        /// camera, the phone too hot): iOS ends it when it can.
        case wait
    }

    static func response(to reason: AVCaptureSession.InterruptionReason?) -> Response {
        reason == .audioDeviceInUseByAnotherClient ? .dropMicrophone : .wait
    }

    /// Said on a video recorded without sound (the web's words).
    static let noSound = "This video has no sound: napsack can't use the microphone."

    /// A call going on: a phone call, or another app's through CallKit.
    static func onCall(_ observer: CXCallObserver = CXCallObserver()) -> Bool {
        observer.calls.contains { !$0.hasEnded }
    }
}

/// What the camera needs of the app's audio session (AVAudioSession), so tests can stand in for it.
protocol AudioSessionControl: AnyObject {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    var isInputAvailable: Bool { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionControl {}

/// The app's audio while the camera has the microphone: set to `whileOpen`
/// as it's taken, and put back as it was when the camera closes, without
/// stopping anyone else's sound. Only on the camera's queue (or in a test, alone).
final class CameraAudioSession {
    private let audio: any AudioSessionControl
    /// How it was before the camera set it; nil while it isn't set.
    private(set) var before: CameraAudio.Setting?

    init(_ audio: any AudioSessionControl = AVAudioSession.sharedInstance()) {
        self.audio = audio
    }

    var isInputAvailable: Bool { audio.isInputAvailable }

    /// Sets it up for recording, mixed with others. False if iOS says no (then the camera goes without the microphone).
    func open() -> Bool {
        if before != nil { return true }
        let was = CameraAudio.Setting(category: audio.category, mode: audio.mode, options: audio.categoryOptions)
        let now = CameraAudio.whileOpen
        do {
            try audio.setCategory(now.category, mode: now.mode, options: now.options)
            try audio.setActive(true, options: [])
        } catch {
            try? audio.setCategory(was.category, mode: was.mode, options: was.options)
            return false
        }
        before = was
        return true
    }

    /// Back as it was. Let go first (others are told, in case they were
    /// waiting), then the old setting; if it can't be let go (something of
    /// napsack's is still playing), it stays mixed with others for now rather
    /// than switching to a setting that would stop them.
    func close() {
        guard let was = before else { return }
        do {
            try audio.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }
        try? audio.setCategory(was.category, mode: was.mode, options: was.options)
        before = nil
    }
}
