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
        // D24: taken from the camera by a call, it's free again once no call's on; taken by
        // something no call explains (a call the call list missed), not again while the camera's open.
        #expect(CameraAudio.takesMicrophone(allowed: true, onCall: false, inputAvailable: true, lost: .toACall))
        #expect(!CameraAudio.takesMicrophone(allowed: true, onCall: true, inputAvailable: true, lost: .toACall))
        #expect(!CameraAudio.takesMicrophone(allowed: true, onCall: false, inputAvailable: true, lost: .toAnotherApp))
    }

    /// D25: a video without sound says why; only a microphone that isn't allowed
    /// gets the sound button, which asks for it, or offers Settings once refused.
    @Test func aVideoWithoutSoundSaysWhyAndAsksOnlyForPermission() {
        #expect(CameraAudio.whyNoSound(.authorized) == .inUse)  // a call had it: the call's words, nothing to ask
        for status: AVAuthorizationStatus in [.notDetermined, .denied, .restricted] {
            #expect(CameraAudio.whyNoSound(status) == .notAllowed, "\(status.rawValue)")
        }
        #expect(CameraAudio.words(.inUse) == CameraAudio.noSound)
        #expect(CameraAudio.words(.notAllowed).hasPrefix("This video has no sound"))
        #expect(CameraAudio.words(.allowedNow).contains("next one will"))
        #expect(CameraAudio.soundTap(.notDetermined) == .ask)
        #expect(CameraAudio.soundTap(.denied) == .openSettings && CameraAudio.soundTap(.restricted) == .openSettings)
        #expect(CameraAudio.soundTap(.authorized) == .allowed)
        #expect(CameraAudio.settingsWords.contains("Settings › napsack"))
        for words in [CameraAudio.words(.notAllowed), CameraAudio.words(.allowedNow), CameraAudio.settingsTitle, CameraAudio.settingsWords] {
            #expect(!words.lowercased().contains("snap"))
        }
    }

    /// D25: a video plays out loud. Sent to you: playback (the ring switch
    /// doesn't mute it), music lowered, not stopped. On the camera without the
    /// microphone: playback, mixed with others.
    @Test func videosAreHeardWithoutStoppingMusic() {
        let playing = CameraAudio.whilePlaying
        #expect(playing.category == .playback && playing.options.contains(.duckOthers) && !playing.options.contains(.mixWithOthers))
        let reviewing = CameraAudio.whileReviewing
        #expect(reviewing.category == .playback && reviewing.options.contains(.mixWithOthers) && !reviewing.options.contains(.duckOthers))
    }

    /// The recorded video on the camera's screen: without the microphone, set
    /// for playback and back as it was; with it, whileOpen stays (it plays out loud already).
    @Test func theCamerasVideoIsHeardWithOrWithoutTheMicrophone() {
        let audio = StandInAudio()
        let camera = CameraAudioSession(audio)
        camera.review()
        #expect(audio.setting == CameraAudio.whileReviewing && audio.active && camera.now == CameraAudio.whileReviewing)
        // The next video takes the microphone: whileOpen, and back to the app's default (not to playback) when it closes.
        #expect(camera.open())
        #expect(audio.setting == CameraAudio.whileOpen && camera.before == StandInAudio.appDefault)
        camera.endReview()  // the microphone's in: stays
        #expect(audio.setting == CameraAudio.whileOpen)
        camera.review()  // already heard
        #expect(audio.setting == CameraAudio.whileOpen)
        camera.close()
        #expect(audio.setting == StandInAudio.appDefault && !audio.active && camera.now == nil)

        // Reviewed and retaken without ever taking the microphone: back as it was.
        camera.review()
        camera.endReview()
        #expect(audio.setting == StandInAudio.appDefault && !audio.active && camera.before == nil)
    }

    /// A video sent to you: set as it plays, back as it was (others told) when
    /// the last closes, even when the next opened before the last closed.
    @Test func aVideoSentToYouIsHeardThenPutBack() {
        let audio = StandInAudio()
        let sound = VideoSound(audio)
        sound.begin()
        #expect(audio.setting == CameraAudio.whilePlaying && audio.active)
        sound.begin()  // the next, back to back, before the first's page closed
        sound.end()
        #expect(audio.setting == CameraAudio.whilePlaying && audio.active)  // still one playing
        sound.end()
        #expect(audio.calls.suffix(2) == ["active false notify", "category soloAmbient"])
        #expect(audio.setting == StandInAudio.appDefault && !audio.active && sound.before == nil)
        sound.end()  // none playing: nothing
        #expect(audio.setting == StandInAudio.appDefault)

        // iOS says no: it plays as the app's audio is, and nothing's put back.
        audio.refuseActive = true
        sound.begin()
        #expect(audio.setting == StandInAudio.appDefault && sound.before == nil)
        sound.end()
        audio.refuseActive = false

        // Still playing as it closes: it stays, and the next close puts it back.
        sound.begin()
        audio.refuseInactive = true
        sound.end()
        #expect(audio.setting == CameraAudio.whilePlaying)
        audio.refuseInactive = false
        sound.begin()
        sound.end()
        #expect(audio.setting == StandInAudio.appDefault && sound.before == nil)
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
