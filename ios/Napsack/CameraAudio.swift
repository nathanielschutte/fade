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

    /// While a recorded video plays on the camera's screen and the camera
    /// hasn't the microphone (D25): heard with the ring switch on silent (the
    /// app's default is muted by it), mixed with whatever else is playing.
    /// With the microphone in, `whileOpen` plays out loud already.
    static let whileReviewing = Setting(category: .playback, mode: .default, options: [.mixWithOthers])

    /// While a video sent to you plays (D25): opening it is asking to hear
    /// it, so the ring switch doesn't mute it; music lowers meanwhile and
    /// comes back up as it closes, never stopped (D21).
    static let whilePlaying = Setting(category: .playback, mode: .moviePlayback, options: [.duckOthers])

    /// iOS took the microphone from the camera (it interrupted the session
    /// for another app) during this opening: while a call it could see was on,
    /// or not.
    enum MicrophoneLoss: Equatable, Sendable {
        case none
        /// A call had it: once no call's on, it's free again.
        case toACall
        /// Something no call explains (a call the call list missed, another
        /// app recording): not taken again until the camera opens anew, so a
        /// video isn't interrupted for it halfway (D24).
        case toAnotherApp
    }

    /// Whether the camera takes the microphone, as it opens or as a video
    /// starts: only when you've allowed it, no call has it, the phone has an
    /// input to give, and nothing unexplained took it from the camera already.
    static func takesMicrophone(allowed: Bool, onCall: Bool, inputAvailable: Bool, lost: MicrophoneLoss = .none) -> Bool {
        allowed && !onCall && inputAvailable && lost != .toAnotherApp
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

    /// Why a recorded video has no sound, as the camera's screen says it.
    enum NoSound: Equatable, Sendable {
        /// The microphone isn't allowed: the sound button asks for it, for the next video.
        case notAllowed
        /// Allowed, but something else had it (a call, D20) or the phone had none: nothing to ask.
        case inUse
        /// Allowed just now: this video has none, the next will.
        case allowedNow
    }

    static func whyNoSound(_ microphone: AVAuthorizationStatus) -> NoSound {
        microphone == .authorized ? .inUse : .notAllowed
    }

    static func words(_ why: NoSound) -> String {
        switch why {
        case .inUse: noSound
        case .notAllowed: "This video has no sound: the microphone is off for napsack. Tap the sound button to turn it on for your next video."
        case .allowedNow: "Microphone on. This video has no sound, but your next one will."
        }
    }

    /// What a tap on a silent video's sound button does, by the microphone's permission.
    enum SoundTap: Equatable, Sendable {
        /// Never asked: iOS asks.
        case ask
        /// Refused before (or restricted): only Settings can turn it on.
        case openSettings
        /// Allowed already: the next video has sound.
        case allowed
    }

    static func soundTap(_ microphone: AVAuthorizationStatus) -> SoundTap {
        switch microphone {
        case .notDetermined: .ask
        case .authorized: .allowed
        default: .openSettings
        }
    }

    /// Offered when the microphone was refused before, to open Settings.
    static let settingsTitle = "The microphone is off"
    static let settingsWords = "To record sound, turn on Microphone in Settings › napsack. This video has no sound; your next one will."

    /// A call going on: a phone call, a FaceTime call, or another app's
    /// through CallKit (the system's call list has them all).
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
/// stopping anyone else's sound. While a recorded video plays and the camera
/// hasn't the microphone, `whileReviewing` instead (D25). Only on the
/// camera's queue (or in a test, alone).
final class CameraAudioSession {
    private let audio: any AudioSessionControl
    /// How it was before the camera set it; nil while it isn't set.
    private(set) var before: CameraAudio.Setting?
    /// What the camera set it to (`whileOpen` or `whileReviewing`); nil while it isn't set.
    private(set) var now: CameraAudio.Setting?

    init(_ audio: any AudioSessionControl = AVAudioSession.sharedInstance()) {
        self.audio = audio
    }

    var isInputAvailable: Bool { audio.isInputAvailable }

    /// Sets it up for recording, mixed with others. False if iOS says no (then the camera goes without the microphone).
    func open() -> Bool { use(CameraAudio.whileOpen) }

    /// A recorded video on screen: heard, mixed with others. With the
    /// microphone in it's heard already, and stays as it is.
    func review() {
        guard now == nil else { return }
        _ = use(CameraAudio.whileReviewing)
    }

    /// The recorded video's gone from the screen: back as it was, unless the microphone's in.
    func endReview() {
        if now == CameraAudio.whileReviewing { close() }
    }

    private func use(_ setting: CameraAudio.Setting) -> Bool {
        if now == setting { return true }
        let was = CameraAudio.Setting(category: audio.category, mode: audio.mode, options: audio.categoryOptions)
        do {
            try audio.setCategory(setting.category, mode: setting.mode, options: setting.options)
            try audio.setActive(true, options: [])
        } catch {
            try? audio.setCategory(was.category, mode: was.mode, options: was.options)
            return false
        }
        if before == nil { before = was }
        now = setting
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
        now = nil
    }
}

/// The app's audio while a video sent to you plays (D25): `whilePlaying`, so
/// the ring switch doesn't mute what you opened to watch, and music lowers
/// rather than stops; back as it was when the last one closes, the others
/// told, so their sound comes back up. Counted: the next video's page can
/// open before the last one's has closed (back to back, X4). Only on the main actor.
@MainActor final class VideoSound {
    static let shared = VideoSound()
    private let audio: any AudioSessionControl
    private var playing = 0
    /// How it was before the first video set it; nil while it isn't set.
    private(set) var before: CameraAudio.Setting?

    init(_ audio: any AudioSessionControl = AVAudioSession.sharedInstance()) {
        self.audio = audio
    }

    /// A video starts: heard. If iOS says no, it plays as the app's audio is.
    func begin() {
        playing += 1
        let was = CameraAudio.Setting(category: audio.category, mode: audio.mode, options: audio.categoryOptions)
        let now = CameraAudio.whilePlaying
        do {
            try audio.setCategory(now.category, mode: now.mode, options: now.options)
            try audio.setActive(true, options: [])
        } catch {
            try? audio.setCategory(was.category, mode: was.mode, options: was.options)
            return
        }
        if before == nil { before = was }
    }

    /// A video's closed: once none is left, back as it was. If it can't be
    /// let go (still playing), it stays for now and the next close tries again.
    func end() {
        playing = max(0, playing - 1)
        guard playing == 0, let was = before else { return }
        do {
            try audio.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }
        try? audio.setCategory(was.category, mode: was.mode, options: was.options)
        before = nil
    }
}
