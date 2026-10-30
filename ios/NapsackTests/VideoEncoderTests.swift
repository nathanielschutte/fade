@preconcurrency import AVFoundation
import Testing
@testable import Napsack

/// The bitrate follows the server's cap: about 2.6 Mbit/s in 4 MB for 10
/// seconds, never more than 3 Mbit/s, and never nothing.
@Test func theBitrateFitsTheCap() {
    #expect((2_500_000...2_700_000).contains(VideoEncoder.bitrate(maxBytes: 4 << 20, seconds: 10)))
    #expect(VideoEncoder.bitrate(maxBytes: 6 << 20, seconds: 10) == 3_000_000)
    #expect(VideoEncoder.bitrate(maxBytes: 100_000, seconds: 10) == 250_000)
    #expect(VideoEncoder.bitrate(maxBytes: 4 << 20, seconds: 0) == 3_000_000)  // a bad limit doesn't divide by zero
}

@Test func theSizeIsAtMost1280AndEven() {
    #expect(VideoEncoder.size(for: CGSize(width: 1920, height: 1080)) == CGSize(width: 1280, height: 720))
    #expect(VideoEncoder.size(for: CGSize(width: 1080, height: 1920)) == CGSize(width: 720, height: 1280))
    #expect(VideoEncoder.size(for: CGSize(width: 640, height: 480)) == CGSize(width: 640, height: 480))
    #expect(VideoEncoder.size(for: CGSize(width: 3840, height: 2161)) == CGSize(width: 1280, height: 720))
}

/// A recording as the camera makes it (1080p turned upright by its transform,
/// with sound and a location) comes out 720p upright, H.264 High, AAC, under
/// the cap, and with nothing of the camera's metadata.
@Test(.timeLimit(.minutes(1))) func aRecordingBecomesWhatIsSent() async throws {
    let source = try await TestMovie.make(seconds: 2)
    defer { try? FileManager.default.removeItem(at: source) }
    // The Simulator's encoder (software) doesn't keep to a bitrate, so the cap
    // here is roomy; a phone's does (measured on a Mac's: 3.18 Mbit/s for 3).
    let cap = 6 << 20
    let out = try await VideoEncoder.mp4(source, maxBytes: cap, seconds: 2)
    defer { try? FileManager.default.removeItem(at: out) }

    let size = try #require(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(size <= cap - VideoEncoder.sealingRoom)
    let asset = AVURLAsset(url: out)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let (natural, transform) = try await video.load(.naturalSize, .preferredTransform)
    let shown = natural.applying(transform)
    #expect(abs(shown.width) == 720 && abs(shown.height) == 1280)  // upright, as recorded
    let format = try #require(try await video.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
    let avcC = try #require(atoms?["avcC"] as? Data)
    #expect(avcC[avcC.startIndex + 1] == 100)  // AVCProfileIndication: High
    let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let audioFormat = try #require(try await audio.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC)
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - 2) < 0.2)
    #expect(try await asset.load(.metadata).isEmpty)  // the source's location isn't carried over
}

/// Without sound (the microphone not allowed), it's still a video.
@Test(.timeLimit(.minutes(1))) func aSilentRecordingStillEncodes() async throws {
    let source = try await TestMovie.make(seconds: 1, sound: false)
    defer { try? FileManager.default.removeItem(at: source) }
    let out = try await VideoEncoder.mp4(source, maxBytes: 4 << 20, seconds: 10)
    defer { try? FileManager.default.removeItem(at: out) }
    let asset = AVURLAsset(url: out)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
}

/// Sound recorded with more than two channels (newer iPhones record four
/// microphones) still comes out as stereo AAC.
@Test(.timeLimit(.minutes(1))) func fourChannelSoundIsMixedToStereo() async throws {
    let source = try await TestMovie.make(seconds: 1, channels: 4)
    defer { try? FileManager.default.removeItem(at: source) }
    let out = try await VideoEncoder.mp4(source, maxBytes: 6 << 20, seconds: 10)
    defer { try? FileManager.default.removeItem(at: out) }
    let audio = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .audio).first)
    let format = try #require(try await audio.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
    #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == 2)
}

/// A cap nothing can fit says so, rather than sending something the server refuses.
@Test(.timeLimit(.minutes(1))) func aCapTooSmallIsSaid() async throws {
    let source = try await TestMovie.make(seconds: 1, sound: false)
    defer { try? FileManager.default.removeItem(at: source) }
    await #expect(throws: VideoEncoder.Problem.tooLarge) {
        _ = try await VideoEncoder.mp4(source, maxBytes: VideoEncoder.sealingRoom + 2_000, seconds: 1)
    }
}

/// Makes test movies the way the camera's look: QuickTime, 1920×1080 frames
/// turned upright by the track's transform, 30 a second, moving detail, and
/// optionally a tone and a location.
enum TestMovie {
    static func make(seconds: Int, sound: Bool = true, channels: UInt32 = 1) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let video = dir.appending(path: "test-video-\(UUID().uuidString).mov")
        try await writeFrames(to: video, seconds: seconds)
        guard sound else { return video }
        defer { try? FileManager.default.removeItem(at: video) }
        let tone = dir.appending(path: "test-tone-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tone) }
        try writeTone(to: tone, seconds: seconds, channels: channels)

        let mix = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), toneAsset = AVURLAsset(url: tone)
        let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let toneTrack = try #require(try await toneAsset.loadTracks(withMediaType: .audio).first)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: Double(seconds), preferredTimescale: 600))
        let v = try #require(mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try v.insertTimeRange(range, of: videoTrack, at: .zero)
        v.preferredTransform = try await videoTrack.load(.preferredTransform)
        let a = try #require(mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: try await toneAsset.load(.duration)), of: toneTrack, at: .zero)

        let out = dir.appending(path: "test-movie-\(UUID().uuidString).mov")
        let export = try #require(AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetPassthrough))
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+40.6892-074.0445/" as NSString
        export.metadata = [location]
        try await export.export(to: out, as: .mov)
        return out
    }

    private static func writeFrames(to url: URL, seconds: Int) async throws {
        let (w, h) = (1920, 1080)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)  // a phone held upright
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            // Stripes that move, over a checkerboard that flips: something to
            // spend bits on. Two rows made per frame, copied down the picture.
            let rows = (0..<2).map { phase in
                (0..<w).flatMap { x -> [UInt8] in
                    [UInt8(truncatingIfNeeded: x + frame * 9), UInt8(truncatingIfNeeded: x * 3 - frame * 5),
                     ((x / 8 + phase + frame) & 1) == 0 ? 230 : 20, 255]
                }
            }
            for y in 0..<h { rows[(y / 8) & 1].withUnsafeBytes { _ = memcpy(base + y * row, $0.baseAddress!, w * 4) } }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private static func writeTone(to url: URL, seconds: Int, channels: UInt32) throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: channels == 4 ? kAudioChannelLayoutTag_Quadraphonic : kAudioChannelLayoutTag_Mono))
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channelLayout: layout)
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: channels]
        if channels > 2 { settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size) }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            let samples = try #require(buffer.floatChannelData?[c])
            for i in 0..<Int(frames) { samples[i] = 0.3 * sin(Float(i) * 2 * .pi * Float(440 + 110 * c) / 44_100) }
        }
        try file.write(from: buffer)
    }
}
