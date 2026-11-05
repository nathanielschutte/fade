@preconcurrency import AVFoundation
import Testing
@testable import Napsack

/// The camera's sound (D20: it froze on a phone call; D21: it stopped music),
/// decided apart from AVFoundation: the Simulator can't place a call or play
/// another app's music.
@MainActor @Suite struct CameraAudioTests {
    /// The microphone only when allowed, no call has it, and the phone has an input.
    @Test func theMicrophoneOnlyWhenNothingElseHasIt() {
        #expect(CameraAudio.takesMicrophone(allowed: true, onCall: false, inputAvailable: true))
        #expect(!CameraAudio.takesMicrophone(allowed: true, onCall: true, inputAvailable: true))  // D20: the call's
        #expect(!CameraAudio.takesMicrophone(allowed: false, onCall: false, inputAvailable: true))  // not allowed
        #expect(!CameraAudio.takesMicrophone(allowed: true, onCall: false, inputAvailable: false))
    }

    /// Interrupted because something else took the microphone: drop it and go
    /// on. Anything else is iOS's to end.
    @Test func eachInterruptionsResponse() {
        #expect(CameraAudio.response(to: .audioDeviceInUseByAnotherClient) == .dropMicrophone)
        for reason: AVCaptureSession.InterruptionReason in [.videoDeviceInUseByAnotherClient, .videoDeviceNotAvailableInBackground,
                                                           .videoDeviceNotAvailableWithMultipleForegroundApps,
                                                           .videoDeviceNotAvailableDueToSystemPressure] {
            #expect(CameraAudio.response(to: reason) == .wait, "\(reason.rawValue)")
        }
        #expect(CameraAudio.response(to: nil) == .wait)
    }

    /// D21: while the camera has the microphone, audio mixes with what's playing, out of the speaker.
    @Test func theCamerasAudioMixesWithOthers() {
        let open = CameraAudio.whileOpen
        #expect(open.category == .playAndRecord && open.mode == .default)
        #expect(open.options.contains(.mixWithOthers) && open.options.contains(.defaultToSpeaker) && open.options.contains(.allowBluetoothA2DP))
        #expect(!open.options.contains(.duckOthers))
    }

    /// Set as the microphone's taken, and back as it was when the camera
    /// closes: let go first (others told), then the old setting.
    @Test func setWhileOpenThenPutBack() {
        let audio = StandInAudio()
        let camera = CameraAudioSession(audio)
        #expect(camera.open())
        #expect(audio.setting == CameraAudio.whileOpen && audio.active)
        #expect(camera.open())  // already: nothing more
        #expect(audio.calls == ["category playAndRecord", "active true"])
        camera.close()
        #expect(audio.calls.suffix(2) == ["active false notify", "category soloAmbient"])
        #expect(audio.setting == StandInAudio.appDefault && !audio.active && camera.before == nil)
        camera.close()  // not open: nothing
        #expect(audio.calls.count == 4)
    }

    /// iOS says no: the camera goes without the microphone, and the setting is as it was.
    @Test func refusedLeavesItAsItWas() {
        let audio = StandInAudio()
        audio.refuseActive = true
        let camera = CameraAudioSession(audio)
        #expect(!camera.open())
        #expect(audio.setting == StandInAudio.appDefault && camera.before == nil)
    }

    /// Something of napsack's still playing (the video on screen): it can't be
    /// let go, so it stays mixed with others rather than switch to a setting
    /// that would stop them, and the next close tries again.
    @Test func stillPlayingStaysMixed() {
        let audio = StandInAudio()
        let camera = CameraAudioSession(audio)
        #expect(camera.open())
        audio.refuseInactive = true
        camera.close()
        #expect(audio.setting == CameraAudio.whileOpen && camera.before != nil)
        audio.refuseInactive = false
        camera.close()
        #expect(audio.setting == StandInAudio.appDefault && camera.before == nil)
    }

    /// The capture session never sets up the app's audio itself (that's what stopped music).
    @Test func theCaptureSessionLeavesAudioToNapsack() {
        let camera = CameraSession(choice: CameraChoice(), audio: CameraAudioSession(StandInAudio()), onCall: { true })
        #expect(!camera.session.automaticallyConfiguresApplicationAudioSession)
    }

    @Test func aVideoWithoutSoundSaysSoInTheWebsWords() {
        #expect(CameraAudio.noSound == "This video has no sound: napsack can't use the microphone.")
    }
}

/// The app's audio session, as iOS keeps it: what it's set to and what was asked.
final class StandInAudio: AudioSessionControl {
    static let appDefault = CameraAudio.Setting(category: .soloAmbient, mode: .default, options: [])
    var setting = appDefault
    var active = false
    var refuseActive = false
    var refuseInactive = false
    var calls: [String] = []
    struct Refused: Error {}

    var category: AVAudioSession.Category { setting.category }
    var mode: AVAudioSession.Mode { setting.mode }
    var categoryOptions: AVAudioSession.CategoryOptions { setting.options }
    var isInputAvailable: Bool { true }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        calls.append("category \(category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "").prefix(1).lowercased())"
                     + "\(category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "").dropFirst())")
        setting = CameraAudio.Setting(category: category, mode: mode, options: options)
    }

    func setActive(_ on: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if on && refuseActive || !on && refuseInactive { throw Refused() }
        calls.append("active \(on)" + (options.contains(.notifyOthersOnDeactivation) ? " notify" : ""))
        active = on
    }
}
