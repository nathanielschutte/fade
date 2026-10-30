@preconcurrency import AVFoundation
import PhotosUI
import SwiftUI

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
    private var facing: AVCaptureDevice.Position = .back
    private var photoDone: CheckedContinuation<Data, any Error>?
    private var movieDone: CheckedContinuation<URL, any Error>?
    /// Shown zoom = the device's zoom factor × this (0.5 on a camera whose
    /// factor 1 is the ultra wide). Only touched on `queue`.
    private var multiplier: CGFloat = 1
    /// A recording that turned out to be a tap: thrown away when it ends.
    private var discarding = false

    /// The zoom a camera offers, as the Camera app shows it.
    struct Lenses: Equatable, Sendable {
        /// The lens buttons: 0.5 (ultra wide), 1, 2, and the telephoto's (3 or 5), as the phone has them.
        var presets: [CGFloat] = [1]
        var min: CGFloat = 1
        var max: CGFloat = 1

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

    static func allowed(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: type)
        default: false
        }
    }

    /// Opens the camera (asking the first time), at 1×. Throws why it can't.
    func start() async throws -> Lenses {
        guard await Self.allowed(.video) else { throw Problem.denied }
        let withSound = await Self.allowed(.audio)  // without it, videos have no sound (the web says so too)
        return try await run { [self] in
            session.beginConfiguration()
            let lenses: Lenses
            do {
                session.sessionPreset = .high
                lenses = try use(facing)
                if withSound, microphone == nil, let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
                   session.canAddInput(input) {
                    session.addInput(input)
                    microphone = input
                }
                if !session.outputs.contains(photo), session.canAddOutput(photo) { session.addOutput(photo) }
                if !session.outputs.contains(movie), session.canAddOutput(movie) { session.addOutput(movie) }
            } catch {
                session.commitConfiguration()
                throw error
            }
            session.commitConfiguration()
            // Only once configured: AVFoundation raises an exception for
            // starting inside beginConfiguration/commitConfiguration (the
            // frozen black camera on a phone, 2026-10-30).
            if !session.isRunning { session.startRunning() }
            return lenses
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    /// The other camera, front or back, at 1×.
    func flip() async throws -> Lenses {
        try await run { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            return try use(facing == .back ? .front : .back)
        }
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

    /// A photo, as JPEG (the front camera's mirrored, as the preview shows it).
    func takePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning else { return continuation.resume(throwing: Problem.noCamera) }
                photoDone = continuation
                Self.orient(photo.connection(with: .video), mirrored: facing == .front)
                photo.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
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

    /// Starts a video, stopping by itself at `seconds`. `stopRecording` gives the file.
    func startRecording(seconds: Int) {
        queue.async { [self] in
            guard session.isRunning, !movie.isRecording else { return }
            movie.maxRecordedDuration = CMTime(seconds: Double(seconds), preferredTimescale: 600)
            Self.orient(movie.connection(with: .video), mirrored: facing == .front)
            let url = FileManager.default.temporaryDirectory.appending(path: "napsack-recording-\(UUID().uuidString).mov")
            movie.startRecording(to: url, recordingDelegate: self)
        }
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
        let recorded: URL = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                movieDone = continuation
                if let pending = pendingMovie {  // the limit stopped it already
                    pendingMovie = nil
                    finishMovie(pending, nil)
                } else if movie.isRecording {
                    movie.stopRecording()
                } else {
                    finishMovie(nil, Problem.failed)
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: recorded) }
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
                try? FileManager.default.removeItem(at: pending)
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        // Reaching the time limit "fails" with the file complete: that's a finished video.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        queue.async { [self] in
            if discarding {
                discarding = false
                try? FileManager.default.removeItem(at: url)
                return
            }
            finishMovie(finished ? url : nil, finished ? nil : Problem.failed)
        }
    }

    private var pendingMovie: URL?

    private func finishMovie(_ url: URL?, _ error: (any Error)?) {
        if let done = movieDone {
            movieDone = nil
            if let url { done.resume(returning: url) } else { done.resume(throwing: error ?? Problem.failed) }
        } else {
            pendingMovie = url  // stopped by the limit before anyone asked
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
        facing = position
        multiplier = Self.multiplier(of: device)
        let lenses = Lenses.of(multiplier: multiplier, switchOvers: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) },
                               minFactor: device.minAvailableVideoZoomFactor, maxFactor: device.maxAvailableVideoZoomFactor)
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = min(max(1 / multiplier, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        }
        return lenses
    }

    /// Shown zoom = factor × this. iOS 18 says; before, a camera with an
    /// ultra wide starts there, and the main camera begins at its first switch-over.
    private static func multiplier(of device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18, *) { return device.displayVideoZoomFactorMultiplier }
        guard device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
              let first = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue, first > 0 else { return 1 }
        return 1 / CGFloat(first)
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
}

/// A capture ready to go: the photo as drawn on, its caption, and where the
/// caption sits (0 top, 1 bottom; recipients see it there, X33).
struct ReadyToSend {
    let media: Captured
    let caption: String
    let y: Double
}

/// What the camera's Send does.
enum CameraSend {
    /// Straight to one chat ("Send to Ben"), from that chat's camera.
    case chat(String, (ReadyToSend) async throws -> Void)
    /// To chats picked on the next screen, from the Camera tab; `done` says where it went.
    case pick([ChatRow], (ChatRow.Kind, ReadyToSend) async throws -> Void, done: (String) -> Void)
}

/// The camera screen. Live: the preview, a shutter (tap for a photo, hold for
/// a video and slide up to zoom it), the lens buttons and pinch, flip, a photo
/// from the library, and close. After a capture it stays here, the photo
/// frozen in place or the video looping (Nate, 2026-10-30: no separate
/// screen), with a caption, the pen (photos), retake, and Send.
struct CameraScreen: View {
    @Environment(\.dismiss) private var dismiss
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
    // The press on the shutter: when it began, where, and the zoom then (for sliding up).
    @State private var pressAt: Date?
    @State private var pressY: CGFloat = 0
    @State private var zoomAtPress: CGFloat = 1
    @State private var holdTask: Task<Void, Never>?
    // After a capture.
    @State private var shot: Captured?
    @State private var caption = ""
    @State private var captionY = 0.75
    @State private var editingCaption = false
    @FocusState private var captionFocused: Bool
    @State private var strokes: [Stroke] = []
    @State private var penOn = false
    @State private var shownSize: CGSize = .zero
    @State private var sending = false
    /// Why the last send didn't go, by the Send button.
    @State private var sendProblem: String?
    @State private var choosing = false
    @State private var prepared: ReadyToSend?

    init(maxSeconds: Int, maxBytes: Int, send: CameraSend, start: Captured? = nil, close: (() -> Void)? = nil) {
        self.maxSeconds = maxSeconds
        self.maxBytes = maxBytes
        self.send = send
        self.close = close
        _shot = State(initialValue: start)
    }

    /// Sliding a held finger up this far zooms in by 1×, as on the web (`ZOOM_SLIDE_PX`).
    static let slidePerZoom: CGFloat = 110
    /// Shorter than this, a press is a tap: a photo. Decided by the touch's own
    /// times, not by when the hold timer ran (D11).
    static let holdSeconds = 0.4

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
            .task {
                do {
                    lenses = try await camera.start()
                    zoom = 1
                    pinchFrom = 1
                } catch { problem = error.localizedDescription }
            }
            .onDisappear { camera.stop() }  // also while choosing who to send to
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    defer { picked = nil }
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        captured(.photo(image))
                    } else {
                        problem = "Couldn't open that photo."
                    }
                }
            }
            .navigationDestination(isPresented: $choosing) {
                if case .pick(let chats, let go, let done) = send, let prepared {
                    SendToScreen(ready: prepared, chats: chats, send: go) { words in
                        retake()
                        done(words)
                    }
                }
            }
        }
        .onDisappear { discardShot() }
    }

    // ---------- live ----------

    private var live: some View {
        VStack {
            HStack {
                Button { camera.stop(); if let close { close() } else { dismiss() } } label: { Image(systemName: "xmark").font(.title2).padding() }
                    .accessibilityLabel("Close")
                Spacer()
                Button {
                    Task {
                        if let flipped = try? await camera.flip() { lenses = flipped }
                        zoom = 1
                        pinchFrom = 1
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).padding()
                }
                .accessibilityLabel("Switch cameras")
                .disabled(recording)
            }
            .foregroundStyle(.white)
            Spacer()
            lensButtons.padding(.bottom, 12)
            ZStack {
                shutter
                HStack {
                    // A photo from the library instead (what the camera's messages offer).
                    PhotosPicker(selection: $picked, matching: .images) {
                        Image(systemName: "photo.on.rectangle").font(.title2).foregroundStyle(.white).padding()
                    }
                    .accessibilityLabel("Choose a photo")
                    .opacity(recording ? 0 : 1)
                    Spacer()
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 30)
        }
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
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
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
        camera.startRecording(seconds: maxSeconds)
    }

    private func photo() {
        guard !recording, shot == nil else { return }
        Task {
            do {
                let data = try await camera.takePhoto()
                guard let image = UIImage(data: data) else { throw CameraSession.Problem.failed }
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

    /// Shown in place; the next capture starts at 1× (Nate, 2026-10-29).
    private func captured(_ media: Captured) {
        shot = media
        zoom = 1
        pinchFrom = 1
        camera.zoom(1)
    }

    // ---------- after a capture ----------

    private func review(_ media: Captured) -> some View {
        ZStack {
            GeometryReader { geo in
                ZStack {
                    switch media {
                    case .photo(let image):
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                        PenLayer(image: image.size, box: geo.size, strokes: $strokes, drawing: penOn)
                    case .video(let url):
                        LoopingPlayer(url: url)
                    }
                    captionBar(in: geo.size)
                }
                .contentShape(Rectangle())
                .onTapGesture { at in
                    // A tap on the picture starts a caption there (as on the web).
                    guard !penOn, !editingCaption, caption.isEmpty else { return }
                    startCaption(at: at.y / max(geo.size.height, 1))
                }
                .onAppear { shownSize = geo.size }
                .onChange(of: geo.size) { _, size in shownSize = size }
            }
            .ignoresSafeArea()
            reviewControls(media)
        }
    }

    @ViewBuilder private func captionBar(in size: CGSize) -> some View {
        if editingCaption || !caption.isEmpty {
            Group {
                if editingCaption {
                    TextField("", text: $caption)
                        .focused($captionFocused)
                        .submitLabel(.done)
                        .onSubmit { editingCaption = false }
                        .onChange(of: caption) { _, c in if c.count > 200 { caption = String(c.prefix(200)) } }
                } else {
                    Text(caption)
                }
            }
            .font(.body).foregroundStyle(.white).multilineTextAlignment(.center)
            .padding(.vertical, 8).padding(.horizontal, 16)
            .frame(width: size.width)
            .background(.black.opacity(0.55))
            // Above the keyboard while it's written; then where it was put.
            .position(x: size.width / 2, y: size.height * (editingCaption ? min(captionY, 0.42) : captionY))
            .gesture(DragGesture().onChanged { drag in
                guard !editingCaption else { return }
                captionY = min(max(drag.location.y / max(size.height, 1), 0.08), 0.92)
            })
            .onTapGesture { startCaption(at: captionY) }
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

    private func reviewControls(_ media: Captured) -> some View {
        VStack {
            HStack(alignment: .top) {
                Button { retake() } label: { Image(systemName: "xmark").font(.title2).padding() }
                    .accessibilityLabel("Retake")
                Spacer()
                VStack(spacing: 18) {
                    if penOn {
                        Button("Done") { penOn = false }.font(.headline)
                        Button { _ = strokes.popLast() } label: { Image(systemName: "arrow.uturn.backward").font(.title3) }
                            .accessibilityLabel("Undo").disabled(strokes.isEmpty)
                    } else {
                        Button { startCaption(at: caption.isEmpty ? 0.75 : captionY) } label: {
                            Image(systemName: "textformat").font(.title2)
                        }
                        .accessibilityLabel("Caption")
                        if case .photo = media {
                            Button { editingCaption = false; penOn = true } label: { Image(systemName: "pencil.tip").font(.title2) }
                                .accessibilityLabel("Draw")
                        }
                    }
                }
                .padding()
            }
            .foregroundStyle(.white)
            .shadow(radius: 3)
            Spacer()
            if !penOn && !editingCaption {
                if let sendProblem {
                    Text(sendProblem).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(10).background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                }
                HStack {
                    Spacer()
                    Button { sendTapped() } label: {
                        HStack(spacing: 8) {
                            if sending { ProgressView().tint(.black) }
                            Text(sendWords).font(.headline).lineLimit(1)
                            Image(systemName: "paperplane.fill")
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .foregroundStyle(.black)
                        .background(.white, in: Capsule())
                    }
                    .disabled(sending)
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
        }
    }

    private var sendWords: String {
        switch send {
        case .chat(let name, _): "Send to \(name)"
        case .pick: "Send to…"
        }
    }

    private func sendTapped() {
        guard let shot else { return }
        editingCaption = false
        var media = shot
        if case .photo(let image) = shot, !strokes.isEmpty {
            media = .photo(Pen.flatten(image, strokes: strokes))
        }
        let ready = ReadyToSend(media: media, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines), y: captionY)
        switch send {
        case .chat(_, let go):
            sending = true
            sendProblem = nil
            Task {
                defer { sending = false }
                do {
                    try await go(ready)
                    retake()
                } catch {
                    Reporter.shared.report(.warn, "sending a pic failed", Reporter.fields(error))
                    sendProblem = error.localizedDescription
                }
            }
        case .pick:
            prepared = ready
            choosing = true
        }
    }

    /// Back to the live camera; a recorded video's file goes.
    private func retake() {
        discardShot()
        caption = ""
        captionY = 0.75
        editingCaption = false
        strokes = []
        penOn = false
        prepared = nil
        sendProblem = nil
    }

    private func discardShot() {
        if case .video(let url) = shot { try? FileManager.default.removeItem(at: url) }
        shot = nil
    }
}

/// A recorded video filling the screen, looping with its sound, until it's sent or retaken.
struct LoopingPlayer: UIViewRepresentable {
    let url: URL

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
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.looper = nil
    }
}

/// Who a pic or video from the Camera tab goes to: any of your chats, as many
/// as you like (the web app's camera tab, Send to…). Back returns to the
/// camera, the pic still there. Chats that can't take one (a changed key, a
/// turned-off account, Team Napsack) aren't offered.
struct SendToScreen: View {
    let ready: ReadyToSend
    let chats: [ChatRow]
    /// Sends to one chat; throws what went wrong there.
    let send: (ChatRow.Kind, ReadyToSend) async throws -> Void
    let done: (String) -> Void
    @State private var picked: [ChatRow.Kind] = []
    @State private var search = ""
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(.red).font(.footnote) }
            ForEach(shown) { row in
                Button {
                    if let i = picked.firstIndex(of: row.kind) { picked.remove(at: i) } else { picked.append(row.kind) }
                } label: {
                    HStack {
                        Avatar(kind: row.kind, avatarId: row.avatarId, name: row.name, size: 32)
                        Text(row.name).foregroundStyle(.primary)
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(sending ? "Sending…" : "Send") { go() }.disabled(picked.isEmpty || sending)
            }
        }
    }

    private var shown: [ChatRow] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? chats.filter { !$0.hidden } : chats.filter { $0.name.localizedStandardContains(words) }
    }

    /// One after another; what failed is said, and only what failed stays picked to try again.
    private func go() {
        sending = true
        problem = nil
        Task {
            defer { sending = false }
            var sent: [String] = [], failed: [(String, String)] = []
            for kind in picked {
                let name = chats.first { $0.kind == kind }?.name ?? "a chat"
                do {
                    try await send(kind, ready)
                    sent.append(name)
                } catch {
                    failed.append((name, error.localizedDescription))
                }
            }
            if failed.isEmpty {
                let word = if case .video = ready.media { "Video" } else { "Pic" }
                done(sent.count == 1 ? "\(word) sent to \(sent[0])." : "\(word) sent to \(sent[0]) and \(sent.count - 1) more.")
            } else {
                picked = picked.filter { kind in failed.contains { $0.0 == chats.first { $0.kind == kind }?.name } }
                problem = failed.map { "Not sent to \($0.0): \($0.1)" }.joined(separator: "\n")
            }
        }
    }
}
