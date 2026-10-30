@preconcurrency import AVFoundation
import PhotosUI
import SwiftUI

/// The camera, done the iOS way (AVFoundation), as the web app's camera does
/// it: tap for a photo, hold for a video (with sound, up to the server's
/// limit), pinch to zoom (back to 1× for each new capture), and flip, the
/// front camera's photo mirrored as the preview shows it. Everything here runs
/// on the camera's own queue, as AVFoundation asks; the screen only calls in.
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

    static func allowed(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: type)
        default: false
        }
    }

    /// Opens the camera (asking the first time). Throws why it can't.
    func start() async throws {
        guard await Self.allowed(.video) else { throw Problem.denied }
        let withSound = await Self.allowed(.audio)  // without it, videos have no sound (the web says so too)
        try await run { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .high
            try use(facing)
            if withSound, microphone == nil, let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
                microphone = input
            }
            if !session.outputs.contains(photo), session.canAddOutput(photo) { session.addOutput(photo) }
            if !session.outputs.contains(movie), session.canAddOutput(movie) { session.addOutput(movie) }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    /// The other camera, front or back.
    func flip() async throws {
        try await run { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            try use(facing == .back ? .front : .back)
        }
    }

    /// Zoom, 1× and up to what the camera allows (at most 10×).
    func zoom(_ factor: CGFloat) {
        queue.async { [self] in
            guard let device = input?.device, (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = min(max(1, factor), min(device.activeFormat.videoMaxZoomFactor, 10))
            device.unlockForConfiguration()
        }
    }

    /// A photo, as JPEG (the front camera's mirrored, as the preview shows it).
    func takePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning else { return continuation.resume(throwing: Problem.noCamera) }
                photoDone = continuation
                photo.connection(with: .video)?.isVideoMirrored = facing == .front
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
            movie.connection(with: .video)?.isVideoMirrored = facing == .front
            let url = FileManager.default.temporaryDirectory.appending(path: "napsack-recording-\(UUID().uuidString).mov")
            movie.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Stops (or waits for the limit to stop it) and gives the recording, as MP4 so every client plays it.
    func stopRecording() async throws -> URL {
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
        return try await Self.mp4(recorded)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        // Reaching the time limit "fails" with the file complete: that's a finished video.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        queue.async { [self] in finishMovie(finished ? url : nil, finished ? nil : Problem.failed) }
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

    /// QuickTime from the camera, made MP4 (H.264 and AAC) at a size the server takes.
    static func mp4(_ source: URL) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appending(path: "napsack-video-\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetMediumQuality) else {
            throw Problem.failed
        }
        try await export.export(to: out, as: .mp4)
        return out
    }

    private func use(_ position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else { throw Problem.noCamera }
        let new = try AVCaptureDeviceInput(device: device)
        if let input { session.removeInput(input) }
        guard session.canAddInput(new) else {
            if let input { session.addInput(input) }
            throw Problem.failed
        }
        session.addInput(new)
        input = new
        facing = position
    }

    private func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do { try work(); continuation.resume() } catch { continuation.resume(throwing: error) }
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

/// Something captured, for the send sheet.
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

/// The camera screen: the preview, a shutter (tap for a photo, hold for a
/// video), flip, and close. What's captured goes to the send sheet.
struct CameraScreen: View {
    @Environment(\.dismiss) private var dismiss
    let maxSeconds: Int
    let captured: (Captured) -> Void
    @State private var camera = CameraSession()
    @State private var problem: String?
    @State private var recording = false
    @State private var recordStart: Date?
    @State private var zoom: CGFloat = 1
    @State private var pinchFrom: CGFloat = 1
    @State private var picked: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()
                .gesture(MagnifyGesture()
                    .onChanged { value in zoom = max(1, pinchFrom * value.magnification); camera.zoom(zoom) }
                    .onEnded { _ in pinchFrom = zoom })
            if let problem {
                Text(problem).foregroundStyle(.white).multilineTextAlignment(.center).padding()
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).padding()
            }
            VStack {
                HStack {
                    Button { camera.stop(); dismiss() } label: { Image(systemName: "xmark").font(.title2).padding() }
                        .accessibilityLabel("Close")
                    Spacer()
                    if zoom > 1.05 { Text(String(format: "%.1f×", zoom)).font(.callout.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule()) }
                    Spacer()
                    Button { Task { try? await camera.flip(); zoom = 1; pinchFrom = 1 } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).padding()
                    }
                    .accessibilityLabel("Switch cameras")
                }
                .foregroundStyle(.white)
                Spacer()
                ZStack {
                    shutter
                    HStack {
                        // A photo from the library instead (what the camera's messages offer).
                        PhotosPicker(selection: $picked, matching: .images) {
                            Image(systemName: "photo.on.rectangle").font(.title2).foregroundStyle(.white).padding()
                        }
                        .accessibilityLabel("Choose a photo")
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 30)
            }
        }
        .statusBarHidden()
        .task {
            do { try await camera.start() } catch { problem = error.localizedDescription }
        }
        .onDisappear { camera.stop() }
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
    }

    /// Tap for a photo; hold (half a second) to record, let go to stop.
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
        .onTapGesture { photo() }
        .onLongPressGesture(minimumDuration: 0.4, perform: {}, onPressingChanged: { pressing in
            if pressing { holdStarted() } else { stopRecording() }  // a quick tap cancels the hold before it starts
        })
        .accessibilityLabel(recording ? "Recording. Let go to stop" : "Take photo. Hold for a video")
        .accessibilityAddTraits(.isButton)
        .sensoryFeedback(.impact(weight: .medium), trigger: recording)
        .disabled(problem != nil)
    }

    private func photo() {
        guard !recording else { return }
        Task {
            do {
                let data = try await camera.takePhoto()
                guard let image = UIImage(data: data) else { throw CameraSession.Problem.failed }
                reset()
                captured(.photo(image))
            } catch { problem = error.localizedDescription }
        }
    }

    @State private var holdTask: Task<Void, Never>?

    private func holdStarted() {
        // A hold, not a tap: decided by time held (as the web, D11), so a quick tap stays a photo.
        holdTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            recording = true
            recordStart = .now
            camera.startRecording(seconds: maxSeconds)
            // At the limit it stops by itself, even while still held (as on the web).
            try? await Task.sleep(for: .seconds(Double(maxSeconds) + 0.2))
            if recording { stopRecording() }
        }
    }

    private func stopRecording() {
        guard recording else { holdTask?.cancel(); return }
        recording = false
        recordStart = nil
        Task {
            do {
                let url = try await camera.stopRecording()
                reset()
                captured(.video(url))
            } catch { problem = error.localizedDescription }
        }
    }

    /// Each new capture starts at 1× (Nate, 2026-10-29).
    private func reset() {
        zoom = 1
        pinchFrom = 1
        camera.zoom(1)
    }
}

/// Where a pic or video from the camera button goes: any of your chats, as
/// many as you like, with one caption (the web app's camera tab, Send to…).
/// Chats that can't take one (a changed key, a turned-off account, Team
/// Napsack) aren't offered.
struct SendToSheet: View {
    @Environment(\.dismiss) private var dismiss
    let media: Captured
    let chats: [ChatRow]
    /// Sends to one chat; throws what went wrong there.
    let send: (ChatRow.Kind, String) async throws -> Void
    let done: (String) -> Void
    @State private var picked: [ChatRow.Kind] = []
    @State private var caption = ""
    @State private var search = ""
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch media {
                    case .photo(let image): Image(uiImage: image).resizable().scaledToFit()
                    case .video(let url): LoopingVideo(url: url)
                    }
                }
                .frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                TextField("Add a caption", text: $caption, axis: .vertical).lineLimit(1...3)
                    .onChange(of: caption) { _, c in if c.count > 200 { caption = String(c.prefix(200)) } }
                    .padding(10).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12)).padding()
                List(shown) { row in
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
                .listStyle(.plain)
                .searchable(text: $search, prompt: "Search")
                if let problem { Text(problem).foregroundStyle(.red).font(.footnote).padding() }
            }
            .navigationTitle(picked.isEmpty ? "Send to…" : "Send to \(picked.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending…" : "Send") { go() }.disabled(picked.isEmpty || sending)
                }
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
                    try await send(kind, caption)
                    sent.append(name)
                } catch {
                    failed.append((name, error.localizedDescription))
                }
            }
            if failed.isEmpty {
                let word = if case .video = media { "Video" } else { "Pic" }
                done(sent.count == 1 ? "\(word) sent to \(sent[0])." : "\(word) sent to \(sent[0]) and \(sent.count - 1) more.")
                dismiss()
            } else {
                picked = picked.filter { kind in failed.contains { $0.0 == chats.first { $0.kind == kind }?.name } }
                problem = failed.map { "Not sent to \($0.0): \($0.1)" }.joined(separator: "\n")
            }
        }
    }
}
