@preconcurrency import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI

/// Which camera a camera screen opens on (Nate, 2026-11-03): the front one
/// after a launch, then whichever was used last, until the app is quit. Only
/// in memory, so a fresh launch starts at the front again (as the web does,
/// `camera.facing`). Read and written from the camera's queue and the screen.
final class CameraChoice: @unchecked Sendable {
    static let shared = CameraChoice()
    private let lock = NSLock()
    private var last: AVCaptureDevice.Position = .front
    private var lastFlash = Flash.off

    /// Where the next camera screen opens.
    var current: AVCaptureDevice.Position { lock.withLock { last } }

    /// A camera opened (or switched to): the next screen opens on it.
    func used(_ position: AVCaptureDevice.Position) { lock.withLock { last = position } }

    /// The flash as last set (off after a launch), kept the same way.
    var flash: Flash {
        get { lock.withLock { lastFlash } }
        set { lock.withLock { lastFlash = newValue } }
    }
}

/// The camera's flash (X50): off, auto, or on, as the Camera app has it.
enum Flash: String, CaseIterable, Sendable {
    case off, auto, on

    var words: String {
        switch self {
        case .off: "Flash off"
        case .auto: "Flash auto"
        case .on: "Flash on"
        }
    }

    var icon: String {
        switch self {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        }
    }
}

/// What the camera in use can light with, as AVFoundation reports it: a
/// flash for photos (the back camera's; on the front, the screen, which
/// AVFoundation lights itself on phones that do that), and a torch, kept on
/// while a video records. The flash button shows only when there's one of
/// them, with the choices this camera has.
struct FlashOffer: Equatable, Sendable {
    /// Photos can flash, and decide for themselves (auto).
    var photo = false
    var photoAuto = false
    /// A light that stays on (the back camera's), for videos.
    var torch = false

    static let none = FlashOffer()

    /// From the photo output's `supportedFlashModes` (which follow the camera in use) and the camera's torch.
    static func of(photoModes: [AVCaptureDevice.FlashMode], torch: Bool) -> FlashOffer {
        FlashOffer(photo: photoModes.contains(.on), photoAuto: photoModes.contains(.auto), torch: torch)
    }

    /// The button's choices, in the order a tap goes through them; none, no button.
    /// Auto is the camera's own judgment (`isFlashScene`), so only where it offers that.
    var modes: [Flash] {
        guard photo || torch else { return [] }
        return photoAuto ? [.off, .auto, .on] : [.off, .on]
    }

    /// What's shown and used: the choice, if this camera has it; otherwise off
    /// (switching to a camera without auto doesn't forget it for the next).
    func shown(_ chosen: Flash) -> Flash { modes.contains(chosen) ? chosen : .off }

    /// A tap on the button: the next choice.
    func next(after current: Flash) -> Flash {
        let modes = modes
        guard let i = modes.firstIndex(of: current) else { return modes.first ?? .off }
        return modes[(i + 1) % modes.count]
    }

    /// The photo's flash setting for a choice (only ever one the output supports).
    func photoMode(_ chosen: Flash) -> AVCaptureDevice.FlashMode {
        switch shown(chosen) {
        case .off: .off
        case .auto: photoAuto ? .auto : .off
        case .on: photo ? .on : .off
        }
    }

    /// Whether the torch is on while a video records: on, or auto when the
    /// camera judges the scene dark enough for a flash (`dark`, its `isFlashScene`).
    func torchOn(_ chosen: Flash, dark: Bool) -> Bool {
        guard torch else { return false }
        switch shown(chosen) {
        case .off: return false
        case .auto: return dark
        case .on: return true
        }
    }
}

/// The camera, done the iOS way (AVFoundation), as the web app's camera does
/// it: tap for a photo, hold for a video (with sound, up to the server's
/// limit), zoom (back to 1× for each new capture), and flip, the front
/// camera's photo mirrored as the preview shows it. Zoom is in the Camera
/// app's terms (1× the main camera, 0.5× the ultra wide), on the phone's
/// real lenses where it has them: the back camera is the multi-camera device
/// that switches lenses itself as the zoom passes each one. Everything here
/// runs on the camera's own queue, as AVFoundation asks; the screen only calls in.
final class CameraSession: NSObject, @unchecked Sendable, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    enum Problem: LocalizedError {
        case noCamera, denied, failed
        var errorDescription: String? {
            switch self {
            case .noCamera: "No camera found. Choose a photo instead."
            case .denied: "Camera access is blocked. Allow it in Settings › napsack, or choose a photo instead."
            case .failed: "The camera couldn't take that. Try again."
            }
        }
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "napsack.camera")
    private var input: AVCaptureDeviceInput?
    private var microphone: AVCaptureDeviceInput?
    private let photo = AVCapturePhotoOutput()
    private let movie = AVCaptureMovieFileOutput()
    private let choice: CameraChoice
    private var facing: AVCaptureDevice.Position
    /// What the camera in use offers, once it's set up (start, flip).
    private var configured: Lenses?
    private var photoDone: CheckedContinuation<Data, any Error>?
    private var movieDone: CheckedContinuation<[URL], any Error>?
    /// The recording so far, one part per camera: switching cameras ends a
    /// part (AVFoundation stops a recording whose camera changes), and the
    /// next starts on the other camera (as the web's does, X37). Joined
    /// before it's sent (VideoEncoder). All of these only on `queue`.
    private var parts: [URL] = []
    /// Seconds allowed in all, and recorded in the parts done.
    private var limit: Double = 10
    private var recorded: Double = 0
    /// A part ending to switch cameras: then this camera, and the next part.
    private var switching: (to: AVCaptureDevice.Position, done: CheckedContinuation<Lenses, any Error>)?
    /// Let go while a part was ending for a switch: that part is the last.
    private var stopAfterSwitch = false
    /// Shown zoom = the device's zoom factor × this (0.5 on a camera whose
    /// factor 1 is the ultra wide). Only touched on `queue`.
    private var multiplier: CGFloat = 1
    /// A recording that turned out to be a tap: thrown away when it ends.
    private var discarding = false
    /// The flash chosen for the recording under way: each part (each camera) lights by it.
    private var recordingFlash = Flash.off
    /// The app's audio while the microphone's in (D21), and whether a call has it (D20).
    private let audio: CameraAudioSession
    private let onCall: @Sendable () -> Bool
    /// You allowed the microphone (asked as the camera first opens).
    private var soundAllowed = false
    private var interruptions: (any NSObjectProtocol)?

    /// The zoom a camera offers, as the Camera app shows it, and its flash.
    struct Lenses: Equatable, Sendable {
        /// The lens buttons: 0.5 (ultra wide), 1, 2, and the telephoto's (3 or 5), as the phone has them.
        var presets: [CGFloat] = [1]
        var min: CGFloat = 1
        var max: CGFloat = 1
        /// What it can light with (worked out once the camera's set up).
        var flash = FlashOffer.none

        /// From a device's numbers: `multiplier` (shown = factor × it), where
        /// it switches lenses (`switchOvers`, in its own factors), and its range.
        static func of(multiplier: CGFloat, switchOvers: [CGFloat], minFactor: CGFloat, maxFactor: CGFloat) -> Lenses {
            let lowest = minFactor * multiplier, highest = Swift.min(maxFactor * multiplier, 15)
            var presets: [CGFloat] = [1]
            if lowest < 0.99 { presets.append((lowest * 10).rounded() / 10) }  // the ultra wide
            if highest >= 2 { presets.append(2) }  // the main camera's 2× (a crop of its sensor on newer phones)
            for at in switchOvers.map({ ($0 * multiplier * 10).rounded() / 10 }) where at > 2.01 && at <= highest {
                presets.append(at)  // a telephoto
            }
            return Lenses(presets: Array(Set(presets)).sorted(), min: Swift.min(lowest, 1), max: Swift.max(highest, 1))
        }
    }

    /// Opens on the camera `choice` says (the front one, after a launch).
    init(choice: CameraChoice = .shared, audio: CameraAudioSession = CameraAudioSession(),
         onCall: @escaping @Sendable () -> Bool = { CameraAudio.onCall() }) {
        self.choice = choice
        self.audio = audio
        self.onCall = onCall
        facing = choice.current
        super.init()
        // napsack sets up its own audio, mixed with others, and only with the microphone in (CameraAudio).
        session.automaticallyConfiguresApplicationAudioSession = false
        interruptions = NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                                                               queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init)
            guard let self else { return }
            queue.async { self.interrupted(reason) }
        }
    }

    deinit {
        if let interruptions { NotificationCenter.default.removeObserver(interruptions) }
    }

    /// Interrupted: for the microphone (a call took it), the camera lets it go
    /// and carries on without it; for anything else, iOS resumes it. Only on `queue`.
    private func interrupted(_ reason: AVCaptureSession.InterruptionReason?) {
        let response = CameraAudio.response(to: reason)
        Task { @MainActor in
            Reporter.shared.report(.info, "camera interrupted", ["reason": String(reason?.rawValue ?? -1), "response": "\(response)"])
        }
        guard response == .dropMicrophone else { return }
        dropMicrophone()
        if !session.isRunning { session.startRunning() }
    }

    /// Takes the microphone if it may (CameraAudio.takesMicrophone), setting
    /// up the app's audio for it first. Only on `queue`, inside a configuration.
    private func takeMicrophone() {
        guard microphone == nil,
              CameraAudio.takesMicrophone(allowed: soundAllowed, onCall: onCall(), inputAvailable: audio.isInputAvailable),
              let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input), audio.open() else { return }
        session.addInput(input)
        microphone = input
    }

    /// Lets the microphone go, and the app's audio back as it was. Only on `queue`.
    private func dropMicrophone() {
        if let microphone {
            session.beginConfiguration()
            session.removeInput(microphone)
            session.commitConfiguration()
            self.microphone = nil
        }
        audio.close()
    }

    static func allowed(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: type)
        default: false
        }
    }

    /// Opens the camera (asking the first time), at 1×. Throws why it can't.
    /// Already running, it stays as it is (a retake goes straight back to it).
    func start() async throws -> Lenses {
        guard await Self.allowed(.video) else { throw Problem.denied }
        let withSound = await Self.allowed(.audio)  // without it, videos have no sound, and say so
        return try await run { [self] in
            soundAllowed = withSound
            if session.isRunning, let configured { return configured }
            session.beginConfiguration()
            var lenses: Lenses
            do {
                session.sessionPreset = .high
                lenses = try use(facing)
                takeMicrophone()  // not on a call (D20)
                if !session.outputs.contains(photo), session.canAddOutput(photo) { session.addOutput(photo) }
                if !session.outputs.contains(movie), session.canAddOutput(movie) { session.addOutput(movie) }
            } catch {
                session.commitConfiguration()
                throw error
            }
            session.commitConfiguration()
            lenses.flash = lighting()  // once the outputs are on this camera
            configured = lenses
            // Only once configured: AVFoundation raises an exception for
            // starting inside beginConfiguration/commitConfiguration (the
            // frozen black camera on a phone, 2026-10-30).
            if !session.isRunning { session.startRunning() }
            return lenses
        }
    }

    func stop() {
        queue.async { [self] in
            torch(false)  // never left on once the camera's closed
            if session.isRunning { session.stopRunning() }
            dropMicrophone()  // the next opening decides again (a call may have begun or ended)
        }
    }

    /// What the camera in use can light with; auto's judgment of the scene
    /// (`isFlashScene`) is watched where photos offer auto. Only on `queue`.
    private func lighting() -> FlashOffer {
        let device = input?.device
        let offer = FlashOffer.of(photoModes: photo.supportedFlashModes,
                                  torch: device.map { $0.hasTorch && $0.isTorchModeSupported(.on) } ?? false)
        if offer.photoAuto {
            let watching = AVCapturePhotoSettings()
            watching.flashMode = .auto
            photo.photoSettingsForSceneMonitoring = watching
        } else {
            photo.photoSettingsForSceneMonitoring = nil
        }
        return offer
    }

    /// The torch on or off, on the camera in use. Only on `queue`.
    private func torch(_ on: Bool) {
        guard let device = input?.device, device.hasTorch, on || device.torchMode != .off,
              (try? device.lockForConfiguration()) != nil else { return }
        if on && device.isTorchModeSupported(.on) {
            try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
        } else {
            device.torchMode = .off
        }
        device.unlockForConfiguration()
    }

    /// The other camera, front or back, at 1×. While recording too: the part
    /// on this camera ends, and the recording goes on with the other.
    func flip() async throws -> Lenses {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let other: AVCaptureDevice.Position = facing == .back ? .front : .back
                if movie.isRecording {
                    guard switching == nil else { return continuation.resume(throwing: Problem.failed) }  // one at a time
                    switching = (other, continuation)
                    movie.stopRecording()  // then fileOutput(_:didFinishRecordingTo:...) switches
                    return
                }
                continuation.resume(with: Result { try reconfigure(other) })
            }
        }
    }

    /// Another camera: its zoom, and its flash (the front may have none, or only the screen's).
    private func reconfigure(_ position: AVCaptureDevice.Position) throws -> Lenses {
        torch(false)  // the camera going off
        session.beginConfiguration()
        var lenses: Lenses
        do {
            lenses = try use(position)
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        lenses.flash = lighting()
        configured = lenses
        return lenses
    }

    /// Zoom as shown (1× the main camera), within what the camera allows.
    /// `smoothly` glides there, as the lens buttons do; otherwise it follows a finger.
    func zoom(_ shown: CGFloat, smoothly: Bool = false) {
        queue.async { [self] in
            guard let device = input?.device, (try? device.lockForConfiguration()) != nil else { return }
            let factor = min(max(shown / multiplier, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, 15 / multiplier))
            if smoothly {
                device.ramp(toVideoZoomFactor: factor, withRate: 8)
            } else {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = factor
            }
            device.unlockForConfiguration()
        }
    }

    /// A photo, as JPEG (the front camera's mirrored, as the preview shows it), with the flash as chosen.
    func takePhoto(flash: Flash = .off) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning else { return continuation.resume(throwing: Problem.noCamera) }
                photoDone = continuation
                Self.orient(photo.connection(with: .video), mirrored: facing == .front)
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                // Only a mode the output has now: any other raises an exception.
                let mode = (configured?.flash ?? .none).photoMode(flash)
                settings.flashMode = photo.supportedFlashModes.contains(mode) ? mode : .off
                photo.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        queue.async { [self] in
            let done = photoDone
            photoDone = nil
            if let data = photo.fileDataRepresentation(), error == nil { done?.resume(returning: data) } else { done?.resume(throwing: Problem.failed) }
        }
    }

    /// Starts a video, stopping by itself at `seconds`, the torch on while it
    /// records if `flash` says so. `stopRecording` gives the file.
    func startRecording(seconds: Int, flash: Flash = .off) {
        queue.async { [self] in
            guard session.isRunning, !movie.isRecording, switching == nil else { return }
            parts.forEach { try? FileManager.default.removeItem(at: $0) }
            parts = []
            recorded = 0
            limit = Double(seconds)
            stopAfterSwitch = false
            recordingFlash = flash
            if microphone == nil {  // without it so far (a call, since ended): this video may have sound
                session.beginConfiguration()
                takeMicrophone()
                session.commitConfiguration()
            }
            startPart()
        }
    }

    /// The next part, on the camera in use, for what's left of the limit.
    private func startPart() {
        // Auto goes by the camera's judgment now (as for a photo); the next camera judges again.
        torch((configured?.flash ?? .none).torchOn(recordingFlash, dark: photo.isFlashScene))
        movie.maxRecordedDuration = CMTime(seconds: limit - recorded, preferredTimescale: 600)
        Self.orient(movie.connection(with: .video), mirrored: facing == .front)
        let url = FileManager.default.temporaryDirectory.appending(path: "napsack-recording-\(UUID().uuidString).mov")
        movie.startRecording(to: url, recordingDelegate: self)
    }

    /// Upright for a phone held up (the app is portrait only), and mirrored for
    /// the front camera as the preview shows it. Mirroring can only be set by
    /// hand once the automatic choice is off (otherwise AVFoundation raises an
    /// exception), and only where the camera supports it.
    static func orient(_ connection: AVCaptureConnection?, mirrored: Bool) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    /// Stops (or waits for the limit to stop it) and gives the recording, as
    /// MP4 that fits the server's cap (VideoEncoder) so every client plays it.
    func stopRecording(maxBytes: Int, seconds: Int) async throws -> URL {
        let recorded: [URL] = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                movieDone = continuation
                if let pending = pendingMovie {  // the limit stopped it already
                    pendingMovie = nil
                    finishMovie(pending, nil)
                } else if switching != nil {
                    stopAfterSwitch = true  // the part ending now is the last
                } else if movie.isRecording {
                    movie.stopRecording()
                } else {
                    finishMovie(nil, Problem.failed)
                }
            }
        }
        defer { recorded.forEach { try? FileManager.default.removeItem(at: $0) } }
        return try await VideoEncoder.mp4(recorded, maxBytes: maxBytes, seconds: seconds)
    }

    /// Stops a recording that was really a tap (D11) and throws it away.
    func discardRecording() {
        queue.async { [self] in
            if movie.isRecording {
                discarding = true
                movie.stopRecording()
            } else if let pending = pendingMovie {
                pendingMovie = nil
                pending.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        // Reaching the time limit "fails" with the file complete: that's a finished video.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        let seconds = output.recordedDuration.seconds
        queue.async { [self] in
            torch(false)  // a part's over: stopped, at the limit, thrown away, or switching cameras
            if finished { parts.append(url); recorded += seconds.isFinite ? seconds : 0 } else { try? FileManager.default.removeItem(at: url) }
            if let (position, done) = switching {
                switching = nil
                done.resume(with: Result { try reconfigure(position) })
                // Onwards on the other camera, unless that was all.
                if !discarding, !stopAfterSwitch, limit - recorded > 0.3 {
                    startPart()
                    return
                }
            }
            stopAfterSwitch = false
            if discarding {
                discarding = false
                parts.forEach { try? FileManager.default.removeItem(at: $0) }
                parts = []
                return
            }
            let all = parts
            parts = []
            finishMovie(all.isEmpty ? nil : all, Problem.failed)
        }
    }

    private var pendingMovie: [URL]?

    private func finishMovie(_ parts: [URL]?, _ error: (any Error)?) {
        if let done = movieDone {
            movieDone = nil
            if let parts { done.resume(returning: parts) } else { done.resume(throwing: error ?? Problem.failed) }
        } else {
            pendingMovie = parts  // stopped by the limit before anyone asked
        }
    }

    /// The cameras to try, best first: on the back, the multi-camera devices
    /// (they switch between the real lenses as the zoom changes); on the front, one camera.
    private static func camera(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices
        return types.lazy.compactMap { type in found.first { $0.deviceType == type } }.first
    }

    /// Switches to the camera facing `position`, at 1×, and says what zoom it offers.
    private func use(_ position: AVCaptureDevice.Position) throws -> Lenses {
        guard let device = Self.camera(position) else { throw Problem.noCamera }
        let new = try AVCaptureDeviceInput(device: device)
        if let input { session.removeInput(input) }
        guard session.canAddInput(new) else {
            if let input { session.addInput(input) }
            throw Problem.failed
        }
        session.addInput(new)
        input = new
        face(position)
        multiplier = Self.multiplier(of: device)
        let lenses = Lenses.of(multiplier: multiplier, switchOvers: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) },
                               minFactor: device.minAvailableVideoZoomFactor, maxFactor: device.maxAvailableVideoZoomFactor)
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = min(max(1 / multiplier, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        }
        configured = lenses
        return lenses
    }

    /// Now on the camera facing `position`: the next camera screen opens on
    /// it, until the app is quit. Only on `queue` (or in a test, alone).
    func face(_ position: AVCaptureDevice.Position) {
        facing = position
        choice.used(position)
    }

    /// The camera this session opens on, or, once open, is using.
    var opensOn: AVCaptureDevice.Position {
        get async { (try? await run { [self] in facing }) ?? .front }
    }

    /// Shown zoom = factor × this: a camera with an ultra wide starts below 1×.
    private static func multiplier(of device: AVCaptureDevice) -> CGFloat {
        device.displayVideoZoomFactorMultiplier
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// What the camera sees, full screen.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class Preview: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: Preview, context: Context) {}
}

/// Something captured.
enum Captured: Identifiable {
    case photo(UIImage)
    case video(URL)
    var id: String {
        switch self {
        case .photo(let image): "p\(ObjectIdentifier(image).hashValue)"
        case .video(let url): url.absoluteString
        }
    }

    var isVideo: Bool {
        if case .video = self { true } else { false }
    }

    /// A photo picked from the library; nil if it can't be opened. The chat's
    /// photo button and the camera's both come this way.
    static func picked(_ item: PhotosPickerItem) async -> Captured? {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = await photo(data) else { return nil }
        return .photo(image)
    }

    /// The longest side a photo is kept at while it's on the camera screen:
    /// enough to fill the largest screen (2868 pixels high), and well over
    /// what's sent (1280).
    static let longestEdge = 2880

    /// A photo from its file's bytes (the camera's, or the library's), upright
    /// and at most `longestEdge` on its longest side, decoded off the main
    /// thread: it shows at once, and a 48-megapixel photo never sits in memory
    /// whole (ImageIO decodes it at the smaller size).
    static func photo(_ data: Data, longestEdge: Int = longestEdge) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,  // from the photo itself, not a small preview in the file
                kCGImageSourceCreateThumbnailWithTransform: true,  // upright, whichever way the file says it was held
                kCGImageSourceThumbnailMaxPixelSize: longestEdge,
                kCGImageSourceShouldCacheImmediately: true,  // decoded here, not when it's first drawn
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
    }
}

/// Photos picked from the library, which can take a while to open (one in
/// iCloud is downloaded first). Meanwhile the picker has closed, so the
/// screen moves on: by the time a photo's ready, the camera may be open, a
/// capture on screen, or another photo picked. Only the newest pick opens,
/// and only onto nothing, so a late one never replaces what's there.
struct PhotoPicks {
    private var newest = 0

    /// A photo's been picked: its number, to ask about once it's opened.
    mutating func began() -> Int {
        newest += 1
        return newest
    }

    /// Whether pick `number` still opens, `busy` while something's on screen it would replace.
    func stillWanted(_ number: Int, busy: Bool) -> Bool { number == newest && !busy }
}

/// The camera as a chat opens it: live, or on a photo picked from the library,
/// frozen in place for its caption, drawing, and Send. One value for both, so
/// the camera opens on what it was opened for, and each opening is a new
/// camera screen.
struct CameraOpening: Identifiable {
    let id = UUID()
    /// What it opens on; nil for the live camera.
    var start: Captured?
}

/// A capture ready to go, made once however many chats it goes to: the photo
/// with what was drawn flattened in and compressed to JPEG, or the video's
/// MP4, both off the main thread; each chat still seals its own copy. With its
/// caption, and where the caption sits (0 top, 1 bottom; recipients see it
/// there, X33).
struct ReadyToSend: Sendable {
    enum Media: Sendable {
        case photo(Data)
        case video(Data)
    }

    let media: Media
    let caption: String
    let y: Double
    /// Where each chat's copy is up to: sent to a chat again (Send again after
    /// a failure, or that chat picked again), it's the same pic, or nothing if it's there.
    var sends = PicSends()

    var isVideo: Bool {
        if case .video = media { true } else { false }
    }

    /// Flattens the drawing into the photo, crops it to what was on screen
    /// (`crop`, its pixels), and compresses it (Pen.flatten, Framing.cropped,
    /// Conversation.photoJPEG), or reads the video's file, off the main thread.
    static func prepare(_ shot: Captured, strokes: [Stroke], crop: CGRect? = nil, caption: String, y: Double) async throws -> ReadyToSend {
        let media = try await Task.detached(priority: .userInitiated) { () throws -> Media in
            switch shot {
            case .photo(let image):
                var flat = Pen.flatten(image, strokes: strokes)
                if let crop { flat = Framing.cropped(flat, to: crop) }
                guard let jpeg = Conversation.photoJPEG(flat) else { throw SendError.tooLarge }
                return .photo(jpeg)
            case .video(let url):
                return .video(try Data(contentsOf: url))
            }
        }.value
        return ReadyToSend(media: media, caption: caption, y: y)
    }

    /// Seals it for `chat` and sends it there, within the server's limits; a
    /// chat that has it already isn't sent it again.
    @MainActor func send(to chat: Conversation, limits: ServerConfig?) async throws {
        let slot = sends.slot(chat.kind)
        guard !slot.sent else { return }
        switch media {
        case .photo(let jpeg): try await chat.sendPhoto(jpeg, caption: caption, y: y, maxBytes: limits?.snapMaxBytes, slot: slot)
        case .video(let mp4): try await chat.sendVideo(mp4, caption: caption, y: y, maxBytes: limits?.videoMaxBytes, slot: slot)
        }
        slot.sent = true
    }
}

/// One ready capture's copies, chat by chat (PicSlot).
@MainActor final class PicSends {
    private var slots: [ChatRow.Kind: PicSlot] = [:]

    nonisolated init() {}

    func slot(_ kind: ChatRow.Kind) -> PicSlot {
        if let kept = slots[kind] { return kept }
        let new = PicSlot()
        slots[kind] = new
        return new
    }
}

/// The capture made ready to send, as it was when Send was tapped. Tapped
/// again with nothing changed (after a failure, or back from Send to…), it's
/// the same one, so every chat gets the same pic with the same id; with the
/// caption, the drawing, or the sound changed, it's a new pic.
struct MadeReady {
    struct Content: Equatable {
        let strokes: [Stroke]
        let caption: String
        let y: Double
        let muted: Bool
        /// The part of the photo that was on screen, in its pixels (Framing.crop).
        var crop: CGRect? = nil
    }

    let content: Content
    let ready: Task<ReadyToSend, any Error>

    /// `kept` when it was made from this content; otherwise a new one, from `make`.
    static func reusing(_ kept: MadeReady?, for content: Content, make: () -> Task<ReadyToSend, any Error>) -> MadeReady {
        if let kept, kept.content == content { return kept }
        return MadeReady(content: content, ready: make())
    }
}

/// A capture on its way: made ready meanwhile (once, for every chat it goes
/// to), whether it's a video known from the start.
struct PicToSend: Sendable {
    let ready: Task<ReadyToSend, any Error>
    let isVideo: Bool
}

/// What the camera's Send does: hands the capture to each chat's
/// Conversation, which shows it at once and sends it when it can (X57), so
/// the camera never waits on the network. They throw only for a chat that
/// isn't there anymore.
enum CameraSend {
    /// Straight to one chat ("Send to Ben"), from that chat's camera, which
    /// the chat closes as it's handed over; with `more`, a "To Ben +" beside Send
    /// opens Send to… with that chat picked, to add others (as on the web).
    case chat(String, @MainActor (PicToSend) throws -> Void, more: AddMore? = nil)
    /// To chats picked on the next screen, from the Camera tab; `done` says where it's going.
    case pick([ChatRow], @MainActor (ChatRow.Kind, PicToSend) throws -> Void, done: (String) -> Void)

    /// From a chat's camera, the other chats it can go to as well.
    struct AddMore {
        /// The chat the camera was opened from: picked to start with.
        let here: ChatRow.Kind
        /// The chats a pic can go to (the chat list's), asked for as they're shown.
        let chats: @MainActor () -> [ChatRow]
        /// Hands it to one chat; throws if that chat's gone.
        let send: @MainActor (ChatRow.Kind, PicToSend) throws -> Void
        /// On its way to every chat picked: says where it's going.
        let done: @MainActor (String) -> Void

        /// Only while this chat is one a pic can go to (the list has it, and
        /// nothing has stopped it since): otherwise it's Send alone, as before.
        @MainActor var offered: Bool { chats().contains { $0.kind == here } }
    }
}

/// The chat list's chats, for a chat's camera to send to as well (Send to…
/// from inside a chat). Always equal to another, as OpenChatLink: it works on
/// the chat list's own state.
struct SendElsewhere: Equatable {
    /// The chats a pic can go to now.
    let chats: @MainActor () -> [ChatRow]
    /// Hands it to one of them.
    let send: @MainActor (ChatRow.Kind, PicToSend) throws -> Void

    static func == (_: SendElsewhere, _: SendElsewhere) -> Bool { true }
}

extension EnvironmentValues {
    /// Set by the chat list for the chats it opens.
    @Entry var sendElsewhere: SendElsewhere? = nil
}

/// A capture's temporary files on the camera screen (a recorded video, its
/// copy without sound): removed on Retake, and when the screen is gone for
/// good. Never just because it disappeared: SwiftUI also says that while a
/// cover is still going up, and a photo picked in a chat was lost to it.
final class CaptureFiles {
    private var urls: [URL] = []

    func keep(_ url: URL) { urls.append(url) }

    func removeAll() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
    }

    deinit { removeAll() }
}

/// The camera screen. Live: the preview, a shutter (tap for a photo, hold for
/// a video and slide up to zoom it), the lens buttons and pinch, a photo from
/// the library and flip on either side of the shutter, and close. After a
/// capture it stays here, the photo frozen in place or the video looping
/// (Nate, 2026-10-30: no separate screen), with a caption, the pen (photos),
/// retake, and Send. The camera runs only while it's live: opened on a picked
/// photo, it starts on Retake.
struct CameraScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    let maxSeconds: Int
    let maxBytes: Int
    let send: CameraSend
    /// What the close button does: in the Camera tab, back to Chats; otherwise it's dismissed.
    var close: (() -> Void)?
    @State private var camera = CameraSession()
    @State private var lenses = CameraSession.Lenses()
    @State private var problem: String?
    @State private var recording = false
    @State private var recordStart: Date?
    @State private var zoom: CGFloat = 1
    @State private var pinchFrom: CGFloat = 1
    @State private var picked: PhotosPickerItem?
    @State private var picks = PhotoPicks()
    // The press on the shutter: when it began, where, and the zoom then (for sliding up).
    @State private var pressAt: Date?
    @State private var pressY: CGFloat = 0
    @State private var zoomAtPress: CGFloat = 1
    @State private var holdTask: Task<Void, Never>?
    // After a capture.
    @State private var shot: Captured?
    /// How the capture sits on screen, which is what's sent (Framing; X52):
    /// a photo from the library whole, zoomable; one just taken filling it.
    @State private var framing = Framing(whole: false)
    /// Where a pinch or drag began.
    @State private var framingFrom: Framing?
    /// The screen it's shown on, in points: what's sent is cropped to it.
    @State private var screen: CGSize = .zero
    @State private var files = CaptureFiles()
    @State private var caption = ""
    @State private var captionY = 0.75
    @State private var editingCaption = false
    @FocusState private var captionFocused: Bool
    @State private var strokes: [Stroke] = []
    @State private var penOn = false
    @State private var sending = false
    /// Why the last send didn't go, by the Send button.
    @State private var sendProblem: String?
    @State private var choosing = false
    /// The capture made ready when Send was last tapped (meanwhile, for Send
    /// to…, while the chats are picked): the same pic each time until it changes.
    @State private var made: MadeReady?
    /// A recorded video's copy without sound, made just after it's recorded;
    /// the sound button sends it instead (as on the web).
    @State private var silent: URL?
    @State private var muted = false
    /// The video on screen was recorded without sound (D20: a call had the microphone).
    @State private var noSound = false
    /// The flash as chosen (CameraChoice keeps it until the app is quit); each camera uses what it has of it.
    @State private var flash = CameraChoice.shared.flash

    /// `offering` stands in for what a camera offers, to look at the screen where there's none (tests);
    /// `caption` and `framing`, a capture as it's being made ready (tests).
    init(maxSeconds: Int, maxBytes: Int, send: CameraSend, start: Captured? = nil, close: (() -> Void)? = nil,
         offering: CameraSession.Lenses? = nil, caption: (String, Double)? = nil, framing: Framing? = nil) {
        self.maxSeconds = maxSeconds
        self.maxBytes = maxBytes
        self.send = send
        self.close = close
        _shot = State(initialValue: start)
        _framing = State(initialValue: Framing(whole: start != nil))  // opened on a photo picked from the library
        if let framing { _framing = State(initialValue: framing) }
        if let caption {
            _caption = State(initialValue: caption.0)
            _captionY = State(initialValue: caption.1)
        }
        if let offering { _lenses = State(initialValue: offering) }
    }

    /// Sliding a held finger up this far zooms in by 1×, as on the web (`ZOOM_SLIDE_PX`).
    static let slidePerZoom: CGFloat = 110
    /// Shorter than this, a press is a tap: a photo. Decided by the touch's own
    /// times, not by when the hold timer ran (D11).
    static let holdSeconds = 0.4
    /// The round buttons' size, in points: easy to hit without aiming (Nate,
    /// 2026-11-03; Apple's guidelines ask for at least 44).
    nonisolated static let button: CGFloat = 48
    /// Between the buttons stacked on the right of a capture.
    static let buttonSpacing: CGFloat = 16

    static func isTap(from: Date, to: Date) -> Bool { to.timeIntervalSince(from) < holdSeconds }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: camera.session).ignoresSafeArea()
                    .gesture(MagnifyGesture()
                        .onChanged { value in
                            guard shot == nil, !recording else { return }  // pinch is for photos; videos zoom by sliding up
                            setZoom(pinchFrom * value.magnification)
                        }
                        .onEnded { _ in pinchFrom = zoom })
                    // A double tap switches cameras, while recording too (a second finger; as on the web).
                    .onTapGesture(count: 2) { if shot == nil { flip() } }
                if let shot {
                    review(shot)
                } else {
                    live
                }
                if let problem, shot == nil {  // the camera's; a capture on screen isn't covered by it
                    Text(problem).foregroundStyle(.white).multilineTextAlignment(.center).padding()
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).padding()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden()
            // Only once it's live: opened on a picked photo, the camera waits for
            // Retake (no camera question, nothing running behind the photo).
            .task(id: shot == nil) {
                guard shot == nil else { return }
                do {
                    lenses = try await camera.start()
                    zoom = 1
                    pinchFrom = 1
                } catch { problem = error.localizedDescription }
            }
            .onDisappear { camera.stop() }  // also while choosing who to send to
            .onChange(of: picked) { _, item in
                guard let item else { return }
                let pick = picks.began()
                Task {
                    defer { picked = nil }
                    let photo = await Captured.picked(item)
                    guard picks.stillWanted(pick, busy: shot != nil || recording) else { return }  // taken over meanwhile
                    if let photo { captured(photo, whole: true) } else { problem = "Couldn't open that photo." }
                }
            }
            .navigationDestination(isPresented: $choosing) {
                if let ready = made?.ready {
                    switch send {
                    case .pick(let chats, let go, let done):
                        SendToScreen(pic: PicToSend(ready: ready, isVideo: shot?.isVideo == true), chats: chats, send: go) { words in
                            retake()
                            done(words)
                        }
                    case .chat(_, _, let more?):
                        // This chat picked to start with; the chat closes the camera once it's sent.
                        SendToScreen(pic: PicToSend(ready: ready, isVideo: shot?.isVideo == true), chats: more.chats(), picked: [more.here],
                                     send: more.send, done: more.done)
                    case .chat:
                        EmptyView()
                    }
                }
            }
        }
    }

    // ---------- live ----------

    private var live: some View {
        VStack(spacing: 0) {
            HStack {
                Button { camera.stop(); if let close { close() } else { dismiss() } } label: { Self.round("xmark") }
                    .accessibilityLabel("Close")
                    .clearOfWindowControls()
                Spacer()
                flashButton
            }
            .padding(.horizontal, 12).padding(.top, 8)
            Spacer()
            lensButtons.padding(.bottom, 16)
            // Under the thumb: a photo from the library left of the shutter, and
            // switching cameras right of it (Nate, 2026-11-03: not up top).
            HStack(spacing: 0) {
                PhotosPicker(selection: $picked, matching: .images) { Self.round("photo.on.rectangle") }
                    .accessibilityLabel("Choose a photo")
                    .opacity(recording ? 0 : 1)
                    .disabled(recording)
                    .frame(maxWidth: .infinity)
                shutter
                Button { flip() } label: { Self.round("arrow.triangle.2.circlepath.camera") }
                    .accessibilityLabel("Switch cameras")
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 24)
        }
    }

    /// Off, auto, or on, tapped through in turn; only where the camera in use
    /// has a flash or a torch (FlashOffer), and not while recording (the
    /// torch was decided as it began).
    @ViewBuilder private var flashButton: some View {
        if !lenses.flash.modes.isEmpty {
            let shown = lenses.flash.shown(flash)
            Button {
                flash = lenses.flash.next(after: shown)
                CameraChoice.shared.flash = flash
            } label: {
                Self.round(shown.icon, color: shown == .off ? .white : .yellow)
            }
            .accessibilityLabel(shown.words)
            .accessibilityHint("Changes the flash")
            .opacity(recording ? 0 : 1)
            .disabled(recording)
        }
    }

    /// An icon on a round, dark button, white on any picture.
    nonisolated private static func round(_ icon: String, color: Color = .white) -> some View {
        Image(systemName: icon)
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: Self.button, height: Self.button)
            .background(.black.opacity(0.35), in: Circle())
            .contentShape(Circle())
    }

    /// The Camera app's lens buttons (.5, 1×, 2, 5, as the phone has them): the
    /// one in use shows the exact zoom; tapping one glides there.
    @ViewBuilder private var lensButtons: some View {
        if lenses.presets.count > 1 {
            let current = lenses.presets.last { $0 <= zoom + 0.01 } ?? lenses.presets[0]
            HStack(spacing: 10) {
                ForEach(lenses.presets, id: \.self) { preset in
                    let on = preset == current
                    Button {
                        zoom = preset
                        pinchFrom = preset
                        camera.zoom(preset, smoothly: true)
                    } label: {
                        Text(on ? Self.zoomWords(zoom) + "×" : Self.zoomWords(preset))
                            .font(.system(size: on ? 13 : 11, weight: .bold))
                            .foregroundStyle(on ? Color.yellow : .white)
                            .frame(width: on ? 38 : 30, height: on ? 38 : 30)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .accessibilityLabel("\(Self.zoomWords(preset)) times zoom")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(6)
            .background(.black.opacity(0.25), in: Capsule())
        } else if zoom > 1.05 {
            Text(Self.zoomWords(zoom) + "×").font(.callout.bold()).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4).background(.black.opacity(0.5), in: Capsule())
        }
    }

    /// "1", "2.4", ".5", as the Camera app writes zoom.
    static func zoomWords(_ z: CGFloat) -> String {
        let r = (z * 10).rounded() / 10
        let text = r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
        return text.hasPrefix("0.") ? String(text.dropFirst()) : text
    }

    private func setZoom(_ wanted: CGFloat) {
        zoom = min(max(wanted, lenses.min), lenses.max)
        camera.zoom(zoom)
    }

    /// Tap for a photo; hold to record, sliding up to zoom; let go to stop.
    private var shutter: some View {
        // The ring only moves while recording; otherwise nothing redraws.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !recording)) { context in
            let progress = recordStart.map { min(1, context.date.timeIntervalSince($0) / Double(maxSeconds)) } ?? 0
            ZStack {
                Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                Circle().trim(from: 0, to: progress).stroke(.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 78, height: 78)
                Circle().fill(recording ? .red : .white).frame(width: recording ? 40 : 64, height: recording ? 40 : 64)
            }
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { pressMoved($0) }
            .onEnded { pressEnded($0) })
        .accessibilityLabel(recording ? "Recording. Let go to stop" : "Take photo. Hold for a video")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { photo() }
        .sensoryFeedback(.impact(weight: .medium), trigger: recording)
        .disabled(problem != nil)
    }

    private func pressMoved(_ press: DragGesture.Value) {
        guard pressAt != nil else {
            pressAt = press.time
            pressY = press.location.y
            holdTask = Task {
                try? await Task.sleep(for: .seconds(Self.holdSeconds))
                guard !Task.isCancelled else { return }
                startRecording()
                // At the limit it stops by itself, even while still held (as on the web).
                try? await Task.sleep(for: .seconds(Double(maxSeconds) + 0.2))
                if !Task.isCancelled, recording { stopRecording() }
            }
            return
        }
        if recording {  // slide up to zoom in, as on the web; back down to where it started
            setZoom(zoomAtPress + max(0, pressY - press.location.y) / Self.slidePerZoom)
        }
    }

    private func pressEnded(_ press: DragGesture.Value) {
        let began = pressAt ?? press.time
        pressAt = nil
        holdTask?.cancel()
        if Self.isTap(from: began, to: press.time) {
            if recording {  // the hold timer ran first, but the finger was up in time: a photo
                recording = false
                recordStart = nil
                camera.discardRecording()
            }
            photo()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        recording = true
        recordStart = .now
        zoomAtPress = zoom
        camera.startRecording(seconds: maxSeconds, flash: lenses.flash.shown(flash))
    }

    private func photo() {
        guard !recording, shot == nil else { return }
        Task {
            do {
                let data = try await camera.takePhoto(flash: lenses.flash.shown(flash))
                guard let image = await Captured.photo(data) else { throw CameraSession.Problem.failed }
                captured(.photo(image))
            } catch { problem = error.localizedDescription }
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        recordStart = nil
        Task {
            do {
                captured(.video(try await camera.stopRecording(maxBytes: maxBytes, seconds: maxSeconds)))
            } catch { problem = error.localizedDescription }
        }
    }

    /// The other camera; recording goes on (CameraSession.flip).
    private func flip() {
        Task {
            if let flipped = try? await camera.flip() { lenses = flipped }
            zoom = 1
            pinchFrom = 1
        }
    }

    /// Shown in place; the next capture starts at 1× (Nate, 2026-10-29).
    private func captured(_ media: Captured, whole: Bool = false) {
        shot = media
        framing = Framing(whole: whole)
        zoom = 1
        pinchFrom = 1
        camera.zoom(1)
        muted = false
        noSound = false
        if case .video(let url) = media {
            files.keep(url)
            Task {
                // Recorded without the microphone (not allowed, or a call had it: CameraAudio): it says so, and there's no sound to turn off.
                guard await VideoEncoder.hasSound(url) else {
                    if case .video(url) = shot { noSound = true }
                    return
                }
                let quiet = try? await VideoEncoder.withoutSound(url)
                // Retaken meanwhile: not this one's.
                if case .video(url) = shot, let quiet {
                    silent = quiet
                    files.keep(quiet)
                } else if let quiet {
                    try? FileManager.default.removeItem(at: quiet)
                }
            }
        }
    }

    // ---------- after a capture ----------

    private func review(_ media: Captured) -> some View {
        ZStack {
            GeometryReader { geo in
                // The picture: the part of the photo on screen, which is what's sent.
                // The pen draws on the whole photo; the caption sits on the picture,
                // where recipients see it on theirs (pic-framing.md).
                let (rect, shown) = Self.place(media, framing: framing, screen: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                        .contentShape(Rectangle())
                        .onTapGesture { if editingCaption { endCaption() } }  // off the picture, only the keyboard goes
                    Group {
                        switch media {
                        case .photo(let image):
                            ZStack {
                                Image(uiImage: image).resizable().scaledToFill()
                                PenLayer(image: image.size, box: rect.size, strokes: $strokes, drawing: penOn)
                            }
                        case .video(let url):
                            LoopingPlayer(url: url, muted: muted)
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(penOn)  // drawing; otherwise taps and pinches are the picture's
                    Color.clear
                        .frame(width: shown.width, height: shown.height)
                        .contentShape(Rectangle())
                        .onTapGesture { at in
                            switch Self.tap(writing: editingCaption, drawing: penOn, captioned: !caption.isEmpty) {
                            case .putKeyboardAway: endCaption()
                            case .startCaption: startCaption(at: at.y / max(shown.height, 1))
                            case .nothing: break
                            }
                        }
                        .overlay { captionBar(in: shown.size) }
                        .offset(x: shown.minX, y: shown.minY)
                        .allowsHitTesting(!penOn)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(framingGesture(media, screen: geo.size), including: framing.movable && !penOn ? .all : .none)
                .onAppear { screen = geo.size }
                .onChange(of: geo.size) { _, size in screen = size }
            }
            .ignoresSafeArea()
            reviewControls(media)
        }
    }

    /// Where the photo is on screen (larger than it, zoomed in or filling) and
    /// the picture (the part of it on screen); a video fills the screen.
    static func place(_ media: Captured, framing: Framing, screen: CGSize) -> (photo: CGRect, shown: CGRect) {
        guard case .photo(let image) = media, image.size.width > 0, image.size.height > 0 else {
            let all = CGRect(origin: .zero, size: screen)
            return (all, all)
        }
        return (framing.photoRect(image: image.size, screen: screen), framing.shown(image: image.size, screen: screen))
    }

    /// A pinch zooms a photo from the library, around the fingers; zoomed in,
    /// a drag moves it. Kept so no gap opens (Framing.kept).
    private func framingGesture(_ media: Captured, screen: CGSize) -> some Gesture {
        let image: CGSize = if case .photo(let i) = media { i.size } else { .zero }
        let pinch = MagnifyGesture()
            .onChanged { value in
                let start = framingFrom ?? framing
                framingFrom = start
                let at = CGPoint(x: value.startAnchor.x * screen.width, y: value.startAnchor.y * screen.height)
                framing = framing.pinched(from: start, by: value.magnification, at: at, moved: .zero, screen: screen)
                    .kept(image: image, screen: screen)
            }
            .onEnded { _ in framingFrom = nil }
        let drag = DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard framing.zoom > 1 else { return }
                let start = framingFrom ?? framing
                framingFrom = start
                var moved = start
                moved.offset = CGSize(width: start.offset.width + value.translation.width, height: start.offset.height + value.translation.height)
                framing = moved.kept(image: image, screen: screen)
            }
            .onEnded { _ in framingFrom = nil }
        return pinch.exclusively(before: drag)
    }

    /// What a tap on the picture does (the caption line takes its own taps).
    enum PictureTap: Equatable { case putKeyboardAway, startCaption, nothing }

    /// Writing a caption, a tap anywhere else puts the keyboard away, and only
    /// that: no new caption, no pen stroke (Nate, 2026-11-03). Otherwise it
    /// starts a caption where it lands (as on the web), unless there's one
    /// already or the pen is on (the pen draws).
    static func tap(writing: Bool, drawing: Bool, captioned: Bool) -> PictureTap {
        if writing { return .putKeyboardAway }
        return drawing || captioned ? .nothing : .startCaption
    }

    /// The caption as recipients will see it (CaptionLook), on a picture `size` points.
    @ViewBuilder private func captionBar(in size: CGSize) -> some View {
        if editingCaption || !caption.isEmpty {
            Group {
                if editingCaption {
                    TextField("", text: $caption, axis: .vertical)
                        .focused($captionFocused)
                        .submitLabel(.done)
                        .onChange(of: caption) { old, new in
                            // No line breaks (Return is done), 200 characters, 5 lines.
                            guard let kept = CaptionLook.typed(new, was: old, width: size.width) else {
                                caption = new.replacingOccurrences(of: "\n", with: "")
                                endCaption()
                                return
                            }
                            if kept != new { caption = kept }
                        }
                } else {
                    Text(caption)
                }
            }
            .captionStrip(width: size.width)
            // Above the keyboard while it's written; then where it was put. Kept inside the picture (CaptionLook.middle).
            .position(x: size.width / 2, y: CaptionLook.middle(editingCaption ? min(captionY, 0.42) : captionY, text: caption, picture: size))
            .gesture(DragGesture().onChanged { drag in
                guard !editingCaption else { return }
                captionY = min(max(drag.location.y / max(size.height, 1), 0.08), 0.92)
            }.onEnded { _ in
                // Where it shows is where it's sent.
                captionY = Double(CaptionLook.middle(captionY, text: caption, picture: size) / max(size.height, 1))
            })
            .onTapGesture { startCaption(at: captionY) }
            .allowsHitTesting(!penOn)  // drawing, the pen goes over it
            .accessibilityLabel(caption.isEmpty ? "Caption" : "Caption: \(caption)")
            .accessibilityHint("Drag up or down to place it")
            .accessibilityAdjustableAction { direction in
                captionY = min(max(captionY + (direction == .increment ? 0.1 : -0.1), 0.08), 0.92)
            }
        }
    }

    private func startCaption(at y: Double) {
        captionY = min(max(y, 0.08), 0.92)
        editingCaption = true
        captionFocused = true
    }

    /// Done writing: the keyboard goes, the caption stays where it was put.
    private func endCaption() {
        editingCaption = false
        captionFocused = false
    }

    private func reviewControls(_ media: Captured) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Button { retake() } label: { Self.round("xmark") }
                    .accessibilityLabel("Retake")
                    .clearOfWindowControls()
                Spacer()
                // Big and well apart, so Aa and the pen aren't hit for each other (Nate, 2026-11-03).
                VStack(alignment: .trailing, spacing: Self.buttonSpacing) {
                    if penOn {
                        Button { penOn = false } label: {
                            Text("Done").font(.headline).foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(minWidth: Self.button, minHeight: Self.button)
                                .background(.black.opacity(0.35), in: Capsule())
                                .contentShape(Capsule())
                        }
                        Button { _ = strokes.popLast() } label: { Self.round("arrow.uturn.backward") }
                            .accessibilityLabel("Undo").disabled(strokes.isEmpty)
                    } else {
                        Button { startCaption(at: caption.isEmpty ? 0.75 : captionY) } label: { Self.round("textformat") }
                            .accessibilityLabel("Caption")
                        if case .photo = media {
                            Button { endCaption(); penOn = true } label: { Self.round("scribble") }
                                .accessibilityLabel("Draw")
                        }
                        if case .video = media, silent != nil {
                            Button { muted.toggle() } label: { Self.round(muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                                .accessibilityLabel(muted ? "Sound off. Tap to send it with sound" : "Sound on. Tap to send it without sound")
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            Spacer()
            if !penOn && !editingCaption {
                if noSound, case .video = media {
                    Label(CameraAudio.noSound, systemImage: "speaker.slash.fill")
                        .font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20).padding(.bottom, 8)
                }
                if let sendProblem {
                    Text(sendProblem).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(10).background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if let more = addMore {
                        // Side by side while they fit; at the largest text, or a long name on a narrow phone, one above the other.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { whoButton(more); sendButton }
                            VStack(alignment: .trailing, spacing: 10) { whoButton(more); sendButton }
                        }
                    } else {
                        sendButton
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
        }
    }

    private var sendButton: some View {
        Button { sendTapped() } label: {
            HStack(spacing: 8) {
                if sending { ProgressView().tint(.black) }
                // Who it goes to stays readable at the largest text: more lines, rather than "Send…".
                Text(sendWords).font(.headline).lineLimit(textSize.isAccessibilitySize ? 4 : 1)
                Image(systemName: "paperplane.fill")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(.black)
            .background(.white, in: buttonShape)
        }
        .disabled(sending)
    }

    /// From a chat: who it's going to, and a tap adds more (Send to… with this
    /// chat picked; app.js, `renderSendWho`). Send beside it just sends.
    private func whoButton(_ more: CameraSend.AddMore) -> some View {
        Button { addTapped() } label: {
            HStack(spacing: 6) {
                // At the largest text, as many lines as the name needs (up to 4), never cut short by the space it's offered.
                Text("To \(sendName)").lineLimit(textSize.isAccessibilitySize ? 4 : 1)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "plus")
            }
            .font(.headline)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(.black.opacity(0.5), in: buttonShape)
            .overlay(buttonShape.stroke(.white.opacity(0.6), lineWidth: 1))
        }
        .disabled(sending)
        .accessibilityLabel("Sending to \(sendName). Add more people or groups")
    }

    /// A capsule, or a rounded box where the words take more than a line.
    private var buttonShape: AnyShape {
        textSize.isAccessibilitySize ? AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous)) : AnyShape(Capsule())
    }

    /// From a chat, the chats it can go to as well, while there are any.
    private var addMore: CameraSend.AddMore? {
        if case .chat(_, _, let more?) = send, more.offered { more } else { nil }
    }

    private var sendName: String {
        if case .chat(let name, _, _) = send { name } else { "" }
    }

    private var sendWords: String {
        switch send {
        // Beside "To Ben +", which says who.
        case .chat(let name, _, _): addMore == nil ? "Send to \(name)" : "Send"
        case .pick: "Send to…"
        }
    }

    /// The capture made ready, off the main thread: kept from the last tap
    /// when nothing's changed since (the same pic, MadeReady), otherwise anew.
    private func ready() -> Task<ReadyToSend, any Error>? {
        guard let shot else { return nil }
        endCaption()
        var crop: CGRect?
        if case .photo(let image) = shot, screen.width > 0, screen.height > 0 {
            crop = framing.crop(image: image.size, screen: screen)
        }
        let content = MadeReady.Content(strokes: strokes, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                        y: captionY, muted: muted && silent != nil, crop: crop)
        var media = shot
        if case .video = shot, content.muted, let silent {
            media = .video(silent)  // a different file: one with no sound in it
        }
        let kept = MadeReady.reusing(made, for: content) {
            Task { try await ReadyToSend.prepare(media, strokes: content.strokes, crop: content.crop, caption: content.caption, y: content.y) }
        }
        made = kept
        return kept.ready
    }

    private func sendTapped() {
        guard let ready = ready() else { return }
        switch send {
        case .chat(_, let go, _):
            sending = true  // once: the chat closes the camera as it takes it
            sendProblem = nil
            do {
                try go(PicToSend(ready: ready, isVideo: shot?.isVideo == true))
            } catch {
                sending = false
                sendProblem = error.localizedDescription
            }
        case .pick:
            choosing = true  // made ready while the chats are picked
        }
    }

    /// "To Ben +": Send to…, with this chat picked.
    private func addTapped() {
        guard ready() != nil else { return }
        sendProblem = nil
        choosing = true
    }

    /// Back to the live camera; a recorded video's files go.
    private func retake() {
        files.removeAll()
        shot = nil
        framing = Framing(whole: false)
        silent = nil
        noSound = false
        muted = false
        caption = ""
        captionY = 0.75
        endCaption()
        strokes = []
        penOn = false
        made = nil  // a new capture is a new pic
        sendProblem = nil
    }
}

/// A recorded video filling the screen, looping with its sound (unless it's
/// to go without), until it's sent or retaken.
struct LoopingPlayer: UIViewRepresentable {
    let url: URL
    var muted = false

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        player.isMuted = muted
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.player?.isMuted = muted
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.looper = nil
    }
}

/// Who a pic or video goes to: any of your chats, as many as you like (the
/// web app's Send to…), from the Camera tab, or from a chat's camera ("To Ben
/// +") with that chat picked to start with. Back returns to the camera, the
/// pic still there. Chats that can't take one (a changed key, a turned-off
/// account, Team Napsack) aren't offered. Send hands it to every chat picked
/// at once (each shows it, and sends it when it can), and is at the bottom
/// right, under the thumb (Nate, 2026-11-09).
struct SendToScreen: View {
    /// The capture, being made ready meanwhile: once, for every chat picked.
    let pic: PicToSend
    let chats: [ChatRow]
    /// Picked as it opens: listed even when hidden, so it can be unpicked.
    let preselected: [ChatRow.Kind]
    /// Hands it to one chat; throws if that chat's gone.
    let send: @MainActor (ChatRow.Kind, PicToSend) throws -> Void
    let done: (String) -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var picked: [ChatRow.Kind]
    @State private var search = ""
    @State private var problem: String?

    init(pic: PicToSend, chats: [ChatRow], picked: [ChatRow.Kind] = [],
         send: @escaping @MainActor (ChatRow.Kind, PicToSend) throws -> Void, done: @escaping (String) -> Void) {
        self.pic = pic
        self.chats = chats
        self.preselected = picked
        self.send = send
        self.done = done
        _picked = State(initialValue: picked)
    }

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(.red).font(.footnote) }
            ForEach(shown) { row in
                Button {
                    if let i = picked.firstIndex(of: row.kind) { picked.remove(at: i) } else { picked.append(row.kind) }
                } label: {
                    HStack {
                        Avatar(kind: row.kind, avatarId: row.avatarId, name: row.name, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).foregroundStyle(.primary)
                            // A friend's @username where their name differs (X47).
                            if let username = row.username, let handle = Person.handle(name: row.name, username: username) {
                                Text(handle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(textSize.isAccessibilitySize ? 3 : 1)  // a long name stays readable at the largest text
                        Spacer()
                        Image(systemName: picked.contains(row.kind) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked.contains(row.kind) ? Color.accentColor : .secondary)
                    }
                }
                .accessibilityAddTraits(picked.contains(row.kind) ? .isSelected : [])
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search")
        .navigationTitle(picked.isEmpty ? "Send to…" : "Send to \(picked.count)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button { go() } label: {
                    HStack(spacing: 8) {
                        Text("Send").font(.headline).lineLimit(1)  // how many, in the title
                        Image(systemName: "paperplane.fill")
                    }
                    .padding(.horizontal, 6)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(picked.isEmpty)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)  // whole at the largest text, over the list's rows
                .accessibilityLabel(picked.isEmpty ? "Send" : "Send to \(picked.count)")
                .accessibilityIdentifier("send-to-send")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private var shown: [ChatRow] { Self.shown(chats, search: search, keeping: preselected) }

    /// The chats listed: those that match what's searched, or with nothing
    /// searched, all but the hidden ones (and the chat it started with, even hidden).
    static func shown(_ chats: [ChatRow], search: String, keeping: [ChatRow.Kind] = []) -> [ChatRow] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? chats.filter { !$0.hidden || keeping.contains($0.kind) }
            : chats.filter { $0.name.localizedStandardContains(words) || $0.username?.localizedStandardContains(words) == true }
    }

    /// Hands it to every chat picked, each sealing its own copy of the same
    /// bytes as it sends. Only a chat that's gone since can't take it: that's
    /// said, and it alone stays picked.
    private func go() {
        problem = nil
        let kinds = picked
        let name = { (kind: ChatRow.Kind) in chats.first { $0.kind == kind }?.name ?? "a chat" }
        var gone: [(ChatRow.Kind, String)] = []
        for kind in kinds {
            do { try send(kind, pic) } catch { gone.append((kind, error.localizedDescription)) }
        }
        let going = kinds.filter { kind in !gone.contains { $0.0 == kind } }.map(name)
        if gone.isEmpty {
            done(Self.words(going, video: pic.isVideo))
        } else {
            picked = gone.map(\.0)
            problem = gone.map { "Not sent to \(name($0.0)): \($0.1)" }.joined(separator: "\n")
        }
    }

    /// Where it's going, for the note after Send.
    static func words(_ names: [String], video: Bool) -> String {
        let word = video ? "video" : "pic"
        return names.count == 1 ? "Sending your \(word) to \(names[0])." : "Sending your \(word) to \(names[0]) and \(names.count - 1) more."
    }
}
