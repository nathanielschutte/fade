@preconcurrency import AVFoundation

/// Turns the camera's movie into what's sent: MP4, H.264 High at most 1280 on
/// its longest side, AAC sound, at a bitrate that fits the server's cap
/// (docs/design/video-quality.md; F20). Only the picture and sound are copied,
/// so nothing of the camera's own file (location, device, time) goes along.
enum VideoEncoder {
    enum Problem: LocalizedError {
        case noVideo, failed, tooLarge
        var errorDescription: String? {
            switch self {
            case .noVideo, .failed: "That video couldn't be made ready to send. Try again."
            case .tooLarge: "That video came out too large to send. Try a shorter one."
            }
        }
    }

    static let longestEdge = 1280
    static let audioBitrate = 64_000
    /// Past this, the hardware encoder gains little at 720p (video-quality.md).
    static let maxVideoBitrate = 3_000_000
    /// Room left in the cap for the encryption's envelope and the caption.
    static let sealingRoom = 16 * 1024

    /// The video bitrate for a cap: what fits in `maxBytes` over `seconds`,
    /// less the sound and a fifth for encoders that overshoot on fast motion.
    static func bitrate(maxBytes: Int, seconds: Int) -> Int {
        let total = Double(max(maxBytes - sealingRoom, 0)) * 8 / Double(max(seconds, 1))
        return Int(min(Double(maxVideoBitrate), max(250_000, total * 0.8 - Double(audioBitrate))))
    }

    /// The size to encode at: the source's, shrunk to `longestEdge`, in even numbers (as the encoder needs).
    static func size(for natural: CGSize) -> CGSize {
        let scale = min(1, CGFloat(longestEdge) / max(natural.width, natural.height, 1))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        return CGSize(width: even(natural.width), height: even(natural.height))
    }

    /// Encodes `source` to a new MP4 that fits `maxBytes` (once more, smaller,
    /// if the first try came out too big). The caller removes the file.
    static func mp4(_ source: URL, maxBytes: Int, seconds: Int) async throws -> URL {
        var bitrate = bitrate(maxBytes: maxBytes, seconds: seconds)
        for attempt in 0..<2 {
            let out = FileManager.default.temporaryDirectory.appending(path: "napsack-video-\(UUID().uuidString).mp4")
            try await encode(source, to: out, videoBitrate: bitrate)
            let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            if size <= maxBytes - sealingRoom { return out }
            try? FileManager.default.removeItem(at: out)
            await Reporter.shared.report(.info, "video over the cap, encoding smaller", ["bytes": String(size), "bitrate": String(bitrate), "attempt": String(attempt)])
            bitrate = Int(Double(bitrate) * Double(maxBytes - sealingRoom) / Double(size) * 0.85)
        }
        throw Problem.tooLarge
    }

    static func encode(_ source: URL, to out: URL, videoBitrate: Int) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Problem.noVideo }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (natural, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let size = size(for: natural)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true  // the index first, so it plays as it arrives

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ] as [String: Any],
        ])
        videoIn.transform = transform  // upright as recorded, whichever way the phone was held
        videoIn.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else { throw Problem.failed }
        reader.add(videoOut)
        writer.add(videoIn)

        var audio: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack {
            let channels = try await audioTrack.load(.formatDescriptions).first
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
            let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: min(max(Int(channels), 1), 2),
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: audioBitrate,
            ])
            if reader.canAdd(audioOut), writer.canAdd(audioIn) {
                reader.add(audioOut)
                writer.add(audioIn)
                audio = (audioOut, audioIn)
            }
        }

        guard reader.startReading(), writer.startWriting() else {
            await Reporter.shared.report(.warn, "video encode failed to start", Reporter.fields(reader.error ?? writer.error ?? Problem.failed))
            throw Problem.failed
        }
        writer.startSession(atSourceTime: .zero)
        // Each track on its own queue; the writer interleaves them.
        async let pictures: Void = pump(videoOut, into: videoIn, on: DispatchQueue(label: "napsack.video-encode.video"))
        if let audio { await pump(audio.0, into: audio.1, on: DispatchQueue(label: "napsack.video-encode.audio")) }
        await pictures
        if reader.status == .failed {
            writer.cancelWriting()
            await Reporter.shared.report(.warn, "video encode failed reading", Reporter.fields(reader.error ?? Problem.failed))
            throw Problem.failed
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            await Reporter.shared.report(.warn, "video encode failed writing", Reporter.fields(writer.error ?? Problem.failed))
            throw Problem.failed
        }
    }

    /// Copies samples until the track ends (or the writer refuses one), on its own queue.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, on queue: DispatchQueue) async {
        final class Once: @unchecked Sendable { var done = false }  // only touched on `queue`
        let once = Once()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while !once.done && input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer(), input.append(sample) { continue }
                    once.done = true
                    input.markAsFinished()
                    finished.resume()
                }
            }
        }
    }
}
