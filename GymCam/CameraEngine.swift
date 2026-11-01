import AVFoundation
import Combine
import CoreImage
import Photos
import UIKit

enum Lens: String, CaseIterable, Identifiable {
    case ultraWide, wide, wide2x, tele

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ultraWide: return ".5"
        case .wide: return "1x"
        case .wide2x: return "2x"
        case .tele: return "5x"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide, .wide2x: return .builtInWideAngleCamera
        case .tele: return .builtInTelephotoCamera
        }
    }

    var zoom: CGFloat { self == .wide2x ? 2 : 1 }
}

enum Resolution: String, CaseIterable, Identifiable {
    case uhd = "4K"
    case hd = "1080p"

    var id: String { rawValue }
    var width: Int32 { self == .uhd ? 3840 : 1920 }
    var height: Int32 { self == .uhd ? 2160 : 1080 }
}

struct CaptureConfig {
    var lens: Lens
    var resolution: Resolution
    var fps: Int
    var exposureBias: Float
    var stabilization: Bool
    var wbAuto: Bool
    var temperature: Float
    var tint: Float
}

/// Owns the capture session, manual camera controls, live grading and recording.
final class CameraEngine: NSObject, ObservableObject {
    static let frameRates = [24, 30, 60]

    // MARK: - UI state (main thread)

    @Published var lens: Lens = .wide {
        didSet { if lens != oldValue { reconfigure(changeDevice: true) } }
    }
    @Published var resolution: Resolution = .uhd {
        didSet { if resolution != oldValue { reconfigure(changeDevice: false) } }
    }
    @Published var fps: Int = 30 {
        didSet { if fps != oldValue { reconfigure(changeDevice: false) } }
    }
    @Published var stabilization = true {
        didSet {
            let on = stabilization
            sessionQueue.async {
                self.session.beginConfiguration()
                self.applyConnection(stabilization: on)
                self.session.commitConfiguration()
            }
        }
    }
    @Published var exposureBias: Float = 0 {
        didSet {
            let value = exposureBias
            sessionQueue.async { self.applyExposureBias(value) }
        }
    }
    @Published var wbAuto = true {
        didSet { if wbAuto != oldValue { wbAutoChanged() } }
    }
    @Published var temperature: Float = 5000 { didSet { pushWhiteBalance() } }
    @Published var tint: Float = 0 { didSet { pushWhiteBalance() } }
    @Published var look: Look = .moody {
        didSet {
            let value = look
            dataQueue.async { self.dLook = value }
        }
    }
    @Published var fxAmount: Float = 1 {
        didSet {
            let value = fxAmount
            dataQueue.async { self.dFx = value }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isSaving = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var aeafLocked = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var availableLenses: [Lens] = []
    @Published private(set) var toast: String?

    // MARK: - Capture plumbing

    let renderer = PreviewRenderer()
    private let pipeline = FilterPipeline()
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "gymcam.session")
    private let dataQueue = DispatchQueue(label: "gymcam.data", qos: .userInitiated)
    private var videoInput: AVCaptureDeviceInput?          // sessionQueue only
    private var configured = false                          // main only
    private var hasAudio = false                            // main only

    // dataQueue only
    private var dLook: Look = .moody
    private var dFx: Float = 1
    private var frameIndex = 0
    private var recorder: MovieRecorder?
    private var wantsRecorderStart = false
    private var pendingAudioSettings: [String: Any]?
    private var recordFps = 30
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!

    // main only
    private var timer: Timer?
    private var recordStart = Date()
    private var suppressWBPush = false

    override init() {
        super.init()
        availableLenses = Lens.allCases.filter { CameraEngine.device(for: $0) != nil }
        if !availableLenses.contains(.wide), let first = availableLenses.first {
            lens = first
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
    }

    private var config: CaptureConfig {
        CaptureConfig(lens: lens, resolution: resolution, fps: fps, exposureBias: exposureBias,
                      stabilization: stabilization, wbAuto: wbAuto, temperature: temperature, tint: tint)
    }

    static func device(for lens: Lens) -> AVCaptureDevice? {
        AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
    }

    /// Where the 9:16 video sits inside a view of the given size (aspect-fit, centered).
    static func previewRect(in size: CGSize) -> CGRect {
        let aspect: CGFloat = 9.0 / 16.0
        var w = size.width
        var h = w / aspect
        if h > size.height {
            h = size.height
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    // MARK: - Session setup

    func start() {
        if configured {
            sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
            return
        }
        configured = true
        let cfg = config
        Task {
            let videoOK = await AVCaptureDevice.requestAccess(for: .video)
            guard videoOK else {
                await MainActor.run { self.permissionDenied = true }
                return
            }
            let audioOK = await AVCaptureDevice.requestAccess(for: .audio)
            self.sessionQueue.async {
                let audioAdded = self.configureSession(cfg, audio: audioOK)
                self.session.startRunning()
                DispatchQueue.main.async { self.hasAudio = audioAdded }
            }
        }
    }

    private func configureSession(_ cfg: CaptureConfig, audio: Bool) -> Bool {
        var audioAdded = false
        session.beginConfiguration()
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        if let device = CameraEngine.device(for: cfg.lens) ?? CameraEngine.device(for: .wide),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if audio,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                audioAdded = true
            }
        }

        applyConnection(stabilization: cfg.stabilization)
        session.commitConfiguration()

        if let device = videoInput?.device { applyFormat(device, cfg) }
        return audioAdded
    }

    /// Portrait frames + stabilization. Call inside begin/commitConfiguration.
    private func applyConnection(stabilization: Bool) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = stabilization ? .cinematicExtended : .off
        }
    }

    private func reconfigure(changeDevice: Bool) {
        guard configured else { return }
        let cfg = config
        sessionQueue.async {
            if changeDevice,
               let device = CameraEngine.device(for: cfg.lens),
               device != self.videoInput?.device {
                self.session.beginConfiguration()
                let old = self.videoInput
                if let old { self.session.removeInput(old) }
                if let new = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(new) {
                    self.session.addInput(new)
                    self.videoInput = new
                } else if let old, self.session.canAddInput(old) {
                    self.session.addInput(old)
                }
                self.applyConnection(stabilization: cfg.stabilization)
                self.session.commitConfiguration()
            }
            if let device = self.videoInput?.device { self.applyFormat(device, cfg) }
        }
    }

    private static func bestFormat(_ device: AVCaptureDevice, _ res: Resolution, _ fps: Int) -> AVCaptureDevice.Format? {
        let matches = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == res.width, dims.height == res.height else { return false }
            guard CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate
            }
        }
        return matches.first(where: { $0.isVideoStabilizationModeSupported(.cinematicExtended) }) ?? matches.first
    }

    /// Resolution, frame rate, SDR color, zoom, focus/exposure modes. sessionQueue only.
    private func applyFormat(_ device: AVCaptureDevice, _ cfg: CaptureConfig) {
        var fps = cfg.fps
        var format = CameraEngine.bestFormat(device, cfg.resolution, fps)
        if format == nil && fps > 30 {
            fps = 30
            format = CameraEngine.bestFormat(device, cfg.resolution, fps)
            let requested = cfg.fps
            DispatchQueue.main.async {
                self.showToast("\(requested) fps isn't available on this lens — using 30")
                self.fps = 30
            }
        }
        guard let format else {
            DispatchQueue.main.async { self.showToast("This lens doesn't support that mode") }
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            if format.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            if format.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
            device.videoZoomFactor = min(max(cfg.lens.zoom, 1), format.videoMaxZoomFactor)
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let bias = min(max(cfg.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(bias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            return
        }
        applyWhiteBalance(device, cfg)
        DispatchQueue.main.async { self.aeafLocked = false }
    }

    // MARK: - Manual controls

    private func applyExposureBias(_ value: Float) {
        guard let device = videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
        let bias = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
        device.setExposureTargetBias(bias, completionHandler: nil)
        device.unlockForConfiguration()
    }

    private func pushWhiteBalance() {
        guard !suppressWBPush, !wbAuto else { return }
        let cfg = config
        sessionQueue.async {
            if let device = self.videoInput?.device { self.applyWhiteBalance(device, cfg) }
        }
    }

    private func wbAutoChanged() {
        let cfg = config
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            if cfg.wbAuto {
                self.applyWhiteBalance(device, cfg)
            } else {
                // Start the manual sliders from what auto WB was doing.
                let current = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                DispatchQueue.main.async {
                    self.suppressWBPush = true
                    self.temperature = min(max(current.temperature, 2500), 9000)
                    self.tint = min(max(current.tint, -60), 60)
                    self.suppressWBPush = false
                    self.pushWhiteBalance()
                }
            }
        }
    }

    private func applyWhiteBalance(_ device: AVCaptureDevice, _ cfg: CaptureConfig) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if cfg.wbAuto {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } else if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: cfg.temperature, tint: cfg.tint)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }

    /// Tap to focus + expose. `lock` keeps them fixed (good when you walk in and out of frame).
    func focus(at point: CGPoint, in size: CGSize, lock: Bool) {
        let rect = CameraEngine.previewRect(in: size)
        guard rect.width > 0, rect.height > 0 else { return }
        let bx = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let by = min(max((point.y - rect.minY) / rect.height, 0), 1)
        let poi = CGPoint(x: by, y: 1 - bx)   // portrait view → landscape sensor coordinates
        aeafLocked = lock
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = poi
                let mode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
                if device.isFocusModeSupported(mode) { device.focusMode = mode }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = poi
                let mode: AVCaptureDevice.ExposureMode = lock ? .autoExpose : .continuousAutoExposure
                if device.isExposureModeSupported(mode) { device.exposureMode = mode }
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard configured, !isRecording, !isSaving, !permissionDenied else { return }
        isRecording = true
        recordingSeconds = 0
        recordStart = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingSeconds = Int(Date().timeIntervalSince(self.recordStart))
        }
        UIApplication.shared.isIdleTimerDisabled = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let audioSettings: [String: Any]? = hasAudio
            ? audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
            : nil
        let fps = self.fps
        dataQueue.async {
            self.pendingAudioSettings = audioSettings
            self.recordFps = fps
            self.wantsRecorderStart = true
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isSaving = true
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        dataQueue.async {
            self.wantsRecorderStart = false
            guard let recorder = self.recorder else {
                DispatchQueue.main.async { self.isSaving = false }
                return
            }
            self.recorder = nil
            recorder.finish { url, _ in
                guard let url else {
                    DispatchQueue.main.async {
                        self.isSaving = false
                        self.showToast("Recording failed")
                    }
                    return
                }
                self.saveToPhotos(url)
            }
        }
    }

    private func startRecorder(width: Int, height: Int) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GymCam-\(UUID().uuidString).mov")
        do {
            recorder = try MovieRecorder(url: url, width: width, height: height,
                                         fps: recordFps, audioSettings: pendingAudioSettings)
        } catch {
            DispatchQueue.main.async {
                self.isRecording = false
                self.timer?.invalidate()
                self.timer = nil
                UIApplication.shared.isIdleTimerDisabled = false
                self.showToast("Couldn't start recording")
            }
        }
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.showToast("Allow Photos access in Settings to save videos")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
            }) { success, _ in
                if !success { try? FileManager.default.removeItem(at: url) }
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.showToast(success ? "Saved to Photos" : "Couldn't save the video")
                }
            }
        }
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    @objc private func appDidEnterBackground() {
        if isRecording { stopRecording() }
    }
}

// MARK: - Frames in

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        frameIndex &+= 1

        if wantsRecorderStart {
            wantsRecorderStart = false
            startRecorder(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        }

        // Full-resolution grade goes into the file.
        if let recorder {
            let graded = pipeline.apply(dLook, to: input, amount: dFx, frame: frameIndex)
            recorder.appendVideo(graded, time: time, context: renderer.ciContext, colorSpace: outputColorSpace)
        }

        // Lighter, downscaled grade for the screen.
        let scale = min(1, 1080 / max(input.extent.width, 1))
        let small = scale < 1 ? input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : input
        renderer.update(pipeline.apply(dLook, to: small, amount: dFx, frame: frameIndex))
    }
}
