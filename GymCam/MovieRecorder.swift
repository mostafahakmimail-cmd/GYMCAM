import AVFoundation
import CoreImage

enum RecorderError: Error {
    case cannotAddVideo
    case cannotStart
    case noFrames
}

/// Writes graded frames + microphone audio to an HEVC .mov file.
/// Every method must be called on the camera's data queue.
final class MovieRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sessionStarted = false
    private var finishing = false

    init(url: URL, width: Int, height: Int, fps: Int, audioSettings: [String: Any]?) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // ~40 Mbps for 4K30, ~10 Mbps for 1080p30 — plenty for grain to survive.
        let bitrate = max(8_000_000, width * height * fps / 6)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        videoInput = video

        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])

        guard writer.canAdd(video) else { throw RecorderError.cannotAddVideo }
        writer.add(video)

        if let audioSettings {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotStart }
    }

    func appendVideo(_ image: CIImage, time: CMTime, context: CIContext, colorSpace: CGColorSpace) {
        guard !finishing, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        context.render(image, to: buffer, bounds: image.extent, colorSpace: colorSpace)
        adaptor.append(buffer, withPresentationTime: time)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, !finishing, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    func finish(_ completion: @escaping (URL?, Error?) -> Void) {
        guard !finishing else { return }
        finishing = true
        guard sessionStarted, writer.status == .writing else {
            writer.cancelWriting()
            completion(nil, writer.error ?? RecorderError.noFrames)
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let writer = self.writer
        let url = self.url
        writer.finishWriting {
            if writer.status == .completed {
                completion(url, nil)
            } else {
                completion(nil, writer.error)
            }
        }
    }
}
