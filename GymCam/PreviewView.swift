import AVKit
import CoreImage
import MetalKit
import SwiftUI

/// Draws the latest graded frame into a Metal view, aspect-fit 9:16.
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let ciContext: CIContext
    private let commandQueue: MTLCommandQueue
    private let lock = NSLock()
    private var latest: CIImage?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init()
    }

    func update(_ image: CIImage) {
        lock.lock()
        latest = image
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let image = latest
        lock.unlock()

        guard let image,
              image.extent.width > 0,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let target = view.drawableSize
        let fitted = CameraEngine.previewRect(in: target)
        let scale = fitted.width / image.extent.width
        let positioned = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: fitted.minX, y: fitted.minY))
        let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: target))
        let composed = positioned.composited(over: background)

        ciContext.render(composed,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: CGRect(origin: .zero, size: target),
                         colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct CameraPreview: UIViewRepresentable {
    let renderer: PreviewRenderer
    /// Fired when a volume button is pressed (start / stop recording).
    let onHardwareButton: () -> Void

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.backgroundColor = .black
        view.isUserInteractionEnabled = true

        if #available(iOS 17.2, *) {
            let action = onHardwareButton
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .ended { action() }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
