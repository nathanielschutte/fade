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
        try await mp4([source], maxBytes: maxBytes, seconds: seconds)
    }

    /// The same for a recording in parts, one after another (one part per
    /// camera, when it was switched while recording).
    static func mp4(_ parts: [URL], maxBytes: Int, seconds: Int) async throws -> URL {
        let source = try await joined(parts)
        var bitrate = bitrate(maxBytes: maxBytes, seconds: seconds)
        for attempt in 0..<2 {
            let out = FileManager.default.temporaryDirectory.appending(path: "napsack-video-\(UUID().uuidString).mp4")
            try await encode(source, to: out, videoBitrate: bitrate)
            let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            if size <= maxBytes - sealingRoom { return out }
            try? FileManager.default.removeItem(at: out)
            await Reporter.shared.report(.info, "video over the cap, encoding smaller", ["bytes": String(size), "bitrate": String(bitrate), "attempt": String(attempt)])
            bitrate = max(100_000, Int(Double(bitrate) * Double(maxBytes - sealingRoom) / Double(size) * 0.85))
        }
        throw Problem.tooLarge
    }

    /// Parts as one asset, back to back. Each camera records at its own size;
    /// the encoder scales every frame to one (`AVVideoScalingModeKey`).
    static func joined(_ parts: [URL]) async throws -> AVAsset {
        guard parts.count > 1 else {
            guard let only = parts.first else { throw Problem.noVideo }
            return AVURLAsset(url: only)
        }
        let joined = AVMutableComposition()
        guard let video = joined.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = joined.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Problem.failed }
        var at = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let (range, transform) = try await track.load(.timeRange, .preferredTransform)
            try video.insertTimeRange(range, of: track, at: at)
            if at == .zero { video.preferredTransform = transform }  // the cameras' are the same: upright, as held
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                let soundRange = try await sound.load(.timeRange).intersection(range)
                if soundRange.duration > .zero { try audio.insertTimeRange(soundRange, of: sound, at: at) }
            }
            at = at + range.duration
        }
        guard at > .zero else { throw Problem.noVideo }
        if audio.segments.isEmpty { joined.removeTrack(audio) }
        return joined
    }

    /// Whether a video has any sound (one recorded without the microphone has none: CameraAudio).
    static func hasSound(_ source: URL) async -> Bool {
        (try? await AVURLAsset(url: source).loadTracks(withMediaType: .audio).isEmpty == false) ?? false
    }

    /// A video's picture size as it plays (turned upright); nil if it can't be read.
    static func uprightSize(_ source: URL) async -> CGSize? {
        guard let track = try? await AVURLAsset(url: source).loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// The same video without its sound (the sound button, as on the web): its
    /// picture copied as it is, nothing encoded again. The caller removes the file.
    static func withoutSound(_ source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Problem.noVideo }
        let picture = AVMutableComposition()
        guard let video = picture.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Problem.failed }
        let (range, transform) = try await track.load(.timeRange, .preferredTransform)
        try video.insertTimeRange(range, of: track, at: .zero)
        video.preferredTransform = transform
        guard let export = AVAssetExportSession(asset: picture, presetName: AVAssetExportPresetPassthrough) else { throw Problem.failed }
        export.shouldOptimizeForNetworkUse = true
        let out = FileManager.default.temporaryDirectory.appending(path: "napsack-video-\(UUID().uuidString).mp4")
        try await export.export(to: out, as: .mp4)
        return out
    }

    static func encode(_ asset: AVAsset, to out: URL, videoBitrate: Int) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Problem.noVideo }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
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

        // Sound, mixed down to stereo while it's read: newer iPhones record
        // more channels than two (four microphones), which AAC at this size
        // can't take as they are (the encode failed on an iPhone 16 Pro).
        var audio: (AVAssetReaderAudioMixOutput, AVAssetWriterInput)?
        if !audioTracks.isEmpty {
            var stereo = AudioChannelLayout()
            stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let layout = Data(bytes: &stereo, count: MemoryLayout<AudioChannelLayout>.size)
            let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: layout,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: layout,
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
        let copied = await copy([(videoOut, videoIn)] + (audio.map { [($0.0, $0.1)] } ?? []), writer: writer)
        if !copied || reader.status == .failed {
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

    /// Copies every track's samples into the writer, each as it's ready for
    /// more (it interleaves them). One loop for all of them, off the main
    /// thread, so a writer that fails partway can't leave anything waiting
    /// for a "ready" that never comes (it hung on GitHub's Simulator with
    /// `requestMediaDataWhenReady`). False if the writer failed or it ran out of time.
    private static func copy(_ tracks: [(AVAssetReaderOutput, AVAssetWriterInput)], writer: AVAssetWriter,
                             deadline: TimeInterval = 120) async -> Bool {
        // AVFoundation's objects aren't Sendable; this loop is the only thing touching them meanwhile.
        struct Handed: @unchecked Sendable {
            let tracks: [(AVAssetReaderOutput, AVAssetWriterInput)]
            let writer: AVAssetWriter
        }
        let handed = Handed(tracks: tracks, writer: writer)
        return await withCheckedContinuation { (finished: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let tracks = handed.tracks, writer = handed.writer
                let giveUp = Date().addingTimeInterval(deadline)
                var open = Array(tracks.indices)
                while !open.isEmpty {
                    guard writer.status == .writing, Date() < giveUp else {
                        for i in open { tracks[i].1.markAsFinished() }
                        return finished.resume(returning: false)
                    }
                    var moved = false
                    for i in open where tracks[i].1.isReadyForMoreMediaData {
                        moved = true
                        if let sample = tracks[i].0.copyNextSampleBuffer() {
                            if !tracks[i].1.append(sample) { break }  // the writer failed: the guard above ends it
                        } else {
                            tracks[i].1.markAsFinished()
                            open.removeAll { $0 == i }
                        }
                    }
                    if !moved { usleep(2_000) }  // the writer is busy with what it has
                }
                finished.resume(returning: true)
            }
        }
    }
}
