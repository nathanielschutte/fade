@preconcurrency import AVFoundation
import Testing
@testable import Napsack

/// A pic or video asked for while the camera isn't running (D24: on a
/// FaceTime call it said there was no camera, and the shutter stayed off),
/// decided apart from AVFoundation: the Simulator can't place a call.
@MainActor @Suite struct CameraCaptureTests {
    /// Running: straight on, nothing done.
    @Test func runningGoesStraightOn() {
        #expect(CameraCapture.steps(running: true, interrupted: false, holdsMicrophone: true, onCall: true, reason: nil) == .init())
        #expect(CameraCapture.ready(running: true, interrupted: false))
        #expect(!CameraCapture.ready(running: true, interrupted: true))
        #expect(!CameraCapture.ready(running: false, interrupted: false))
    }

    /// Interrupted because a call took the microphone: let it go, start again, and wait.
    @Test func aCallsInterruptionLetsTheMicrophoneGo() {
        let steps = CameraCapture.steps(running: false, interrupted: true, holdsMicrophone: true, onCall: false,
                                        reason: .audioDeviceInUseByAnotherClient)
        #expect(steps == .init(dropMicrophone: true, startRunning: true, wait: true))
        // On a call, whatever the reason: the microphone's the call's.
        #expect(CameraCapture.steps(running: false, interrupted: false, holdsMicrophone: true, onCall: true, reason: nil).dropMicrophone)
    }

    /// Another app has the camera itself for a moment (FaceTime): the
    /// microphone's no help, so it stays; the camera's started and waited for.
    @Test func theCameraTakenForAMomentIsWaitedFor() {
        let steps = CameraCapture.steps(running: false, interrupted: true, holdsMicrophone: true, onCall: false,
                                        reason: .videoDeviceInUseByAnotherClient)
        #expect(steps == .init(dropMicrophone: false, startRunning: true, wait: true))
        // Running but still marked interrupted: not started again, only waited for.
        #expect(CameraCapture.steps(running: true, interrupted: true, holdsMicrophone: false, onCall: false, reason: nil)
            == .init(dropMicrophone: false, startRunning: false, wait: true))
        // Stopped (no interruption, no microphone): started, and waited for.
        #expect(CameraCapture.steps(running: false, interrupted: false, holdsMicrophone: false, onCall: false, reason: nil)
            == .init(dropMicrophone: false, startRunning: true, wait: true))
    }

    /// Tapped as the camera opens (not set up yet): opening starts it, so a capture only waits.
    @Test func notSetUpYetOnlyWaits() {
        #expect(CameraCapture.steps(setUp: false, running: false, interrupted: false, holdsMicrophone: false, onCall: false, reason: nil)
            == .init(dropMicrophone: false, startRunning: false, wait: true))
        #expect(!CameraCapture.ready(setUp: false, running: true, interrupted: false))
    }

    /// The wait is short: a tap still feels like a tap.
    @Test func theWaitIsBrief() {
        #expect(CameraCapture.wait > 0 && CameraCapture.wait <= 3)
        #expect(CameraCapture.noteSeconds > 0)
    }

    /// Still paused after waiting: said plainly, never "no camera".
    @Test func pausedIsSaidPlainly() {
        let words = CameraSession.Problem.paused.localizedDescription
        #expect(words == "The camera is paused while another app uses it. Try again in a moment.")
        #expect(!words.lowercased().contains("snap"))
        #expect(CameraSession.Problem.paused.localizedDescription != CameraSession.Problem.noCamera.localizedDescription)
    }

    /// A failed capture's report: the kind, why, and the camera's state, and nothing else.
    @Test func aFailedCaptureIsReportedWithTheCamerasState() {
        let at = CameraCapture.Conditions(running: false, interrupted: true, onCall: true,
                                          reason: AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient.rawValue, holdsMicrophone: false)
        let fields = CameraCapture.fields(.photo, CameraSession.Problem.paused, at)
        #expect(fields["kind"] == "photo" && fields["reason"] == "paused")
        #expect(fields["running"] == "false" && fields["interrupted"] == "true" && fields["on_call"] == "true")
        #expect(fields["interruption"] == String(AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient.rawValue))
        #expect(fields["microphone"] == "false")
        #expect(fields["error"] == CameraSession.Problem.paused.localizedDescription)
        #expect(Set(fields.keys) == ["kind", "reason", "running", "interrupted", "interruption", "on_call", "microphone", "error"])

        struct Other: Error {}
        let video = CameraCapture.fields(.video, Other(), CameraCapture.Conditions())
        #expect(video["kind"] == "video" && video["reason"] == "other" && video["interruption"] == "none")
        // None of the names is one the server redacts (CLAUDE.md, Logging): they reach the log viewer as they are.
        for name in fields.keys {
            for redacted in ["text", "body", "plain", "caption", "password", "secret", "token", "key", "cipher", "invite"] {
                #expect(!name.contains(redacted), "\(name)")
            }
            #expect(!["message", "msg", "content"].contains(name))
        }
    }

    /// The camera isn't running (none on a Simulator): a photo waits briefly
    /// for it, then says it's paused rather than that there's no camera, and
    /// the next one tries again.
    @Test func aPhotoWhileTheCameraIsntRunningSaysItsPaused() async {
        let camera = CameraSession(choice: CameraChoice(), audio: CameraAudioSession(StandInAudio()), onCall: { false })
        for _ in 0..<2 {
            do {
                _ = try await camera.takePhoto()
                Issue.record("a photo without a camera")
            } catch {
                #expect((error as? CameraSession.Problem).map { "\($0)" } == "paused")
            }
        }
    }

    /// A video asked for while the camera isn't running, let go before it
    /// got going: the stop says it's paused (not that it failed), and nothing starts after.
    @Test func aVideoLetGoWhileTheCameraGetsGoingSaysItsPaused() async {
        let camera = CameraSession(choice: CameraChoice(), audio: CameraAudioSession(StandInAudio()), onCall: { false })
        let failed = Failed()
        camera.startRecording(seconds: 10) { failed.error = $0 }
        do {
            _ = try await camera.stopRecording(maxBytes: 1 << 20, seconds: 10)
            Issue.record("a video without a camera")
        } catch {
            #expect((error as? CameraSession.Problem).map { "\($0)" } == "paused")
        }
        #expect(failed.error == nil)  // the stop said it; the start says nothing more
    }

    /// Held on while it never got going: the start says it's paused.
    @Test func aVideoHeldWhileTheCameraNeverRunsSaysItsPaused() async {
        let camera = CameraSession(choice: CameraChoice(), audio: CameraAudioSession(StandInAudio()), onCall: { false })
        let error: (any Error)? = await withCheckedContinuation { done in
            camera.startRecording(seconds: 10) { done.resume(returning: $0) }
        }
        #expect((error as? CameraSession.Problem).map { "\($0)" } == "paused")
    }
}

@MainActor private final class Failed {
    var error: (any Error)?
}
