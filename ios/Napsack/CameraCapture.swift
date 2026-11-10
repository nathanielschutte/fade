@preconcurrency import AVFoundation

/// A pic or video asked for while the camera isn't running (D24). On a call,
/// iOS interrupts the capture session for a moment (the call takes the
/// microphone, or FaceTime the camera), and an interrupted session isn't
/// running. A capture then never just fails: the camera is got going again
/// (letting the microphone go if a call has it), waited for briefly (until it
/// says it's running, or its interruption has ended), and only if it still
/// isn't is that said, plainly, without turning anything off: the next tap
/// tries again. These are the decisions; the camera (CameraSession) carries
/// them out.
enum CameraCapture {
    enum Kind: String, Sendable {
        case photo, video
    }

    /// What's done before a capture, from where the camera is.
    struct Steps: Equatable, Sendable {
        /// Let the microphone go: a call has it, and holding on keeps the camera interrupted (D20).
        var dropMicrophone = false
        /// Start the session again (it stopped, or was interrupted).
        var startRunning = false
        /// Then wait for it to run, up to `wait`.
        var wait = false
    }

    /// Running and not interrupted: straight on. Otherwise get it going, and
    /// wait. Not yet set up (tapped as the camera opens), opening starts it:
    /// only wait.
    static func steps(setUp: Bool = true, running: Bool, interrupted: Bool, holdsMicrophone: Bool, onCall: Bool,
                      reason: AVCaptureSession.InterruptionReason?) -> Steps {
        if ready(setUp: setUp, running: running, interrupted: interrupted) { return Steps() }
        return Steps(dropMicrophone: holdsMicrophone && (onCall || CameraAudio.response(to: reason) == .dropMicrophone),
                     startRunning: setUp && !running, wait: true)
    }

    /// Whether a capture can go now: set up (a camera in, its picture
    /// flowing), running, and not interrupted.
    static func ready(setUp: Bool = true, running: Bool, interrupted: Bool) -> Bool { setUp && running && !interrupted }

    /// The longest a capture waits for the camera to run again: long enough
    /// for a call's moment to pass, short enough that a tap still feels like one.
    static let wait: TimeInterval = 2

    /// How long a capture's problem is said, over the live camera, unless the camera runs again first.
    static let noteSeconds: Double = 4

    /// Where the camera was when a capture failed, for the log viewer.
    struct Conditions: Equatable, Sendable {
        var running = false
        var interrupted = false
        var onCall = false
        /// The last interruption's reason (AVCaptureSession.InterruptionReason), if it hasn't ended.
        var reason: Int?
        var holdsMicrophone = false
    }

    /// A failed capture's report: what it was, why, and where the camera was.
    /// Only the camera's own state: no picture, nothing typed.
    @MainActor static func fields(_ kind: Kind, _ error: any Error, _ at: Conditions) -> [String: String] {
        let why = (error as? CameraSession.Problem).map { "\($0)" } ?? "other"
        return Reporter.fields(error, [
            "kind": kind.rawValue,
            "reason": why,
            "running": String(at.running),
            "interrupted": String(at.interrupted),
            "interruption": at.reason.map(String.init) ?? "none",
            "on_call": String(at.onCall),
            "microphone": String(at.holdsMicrophone),
        ])
    }
}
