import MetalKit
import SwiftUI

struct DustSnapshot {
    let id = UUID()
    let image: CGImage
    let size: CGSize
}

/// Matches DustUniforms in DustShaders.metal (40 bytes, 8-byte alignment).
struct DustUniforms {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var contentSize: SIMD2<Float>
    var grid: SIMD2<UInt32>
    var time: Float
    var seed: Float
}

/// Layout shared with MorphUniforms in Metal: 72 bytes.
struct MorphUniforms {
    var viewport: SIMD2<Float>
    var sourceOrigin: SIMD2<Float>
    var sourceSize: SIMD2<Float>
    var targetOrigin: SIMD2<Float>
    var targetSize: SIMD2<Float>
    var grid: SIMD2<UInt32>
    var time: Float
    var sourceCount: UInt32
    var cornerRadius: Float
    var loadingStart: Float
    var loadingEnd: Float
    var formationEnd: Float
}

enum DustRendererError: LocalizedError {
    case unavailable, missingShaders, textureAllocation

    var errorDescription: String? {
        switch self {
        case .unavailable: "设备不支持 Metal"
        case .missingShaders: "未找到粒子着色器"
        case .textureAllocation: "无法创建文字纹理"
        }
    }
}

/// No per-frame CPU particle updates. The morph uses two instanced draw calls:
/// departing text fragments, then image tiles traveling from glyphs to their destination.
final class DustRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let morphPipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var targetTexture: MTLTexture?
    private var glyphBuffer: MTLBuffer?
    private(set) var glyphCount = 0
    private var snapshotID: UUID?
    private(set) var contentSize = CGSize.zero

    var time: Float = 0
    var particleSize: CGFloat = 1
    var origin = CGPoint.zero
    var mode: DustEffectMode = .dissolve
    var targetFrame = CGRect.zero
    var targetCornerRadius: Float = 20

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else {
            throw DustRendererError.unavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw DustRendererError.missingShaders
        }
        func makePipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment) else {
                throw DustRendererError.missingShaders
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.device = device
        self.queue = queue
        self.pipeline = try makePipeline(vertex: "dustVertex", fragment: "dustFragment")
        self.morphPipeline = try makePipeline(vertex: "morphVertex", fragment: "morphFragment")
        super.init()
    }

    func setSnapshot(_ snapshot: DustSnapshot) throws {
        guard snapshotID != snapshot.id else { return }
        let (newTexture, bytes) = try makeTexture(snapshot.image)
        let width = snapshot.image.width
        let height = snapshot.image.height
        var glyphs: [SIMD4<Float>] = []
        let scaleX = CGFloat(width) / snapshot.size.width
        let scaleY = CGFloat(height) / snapshot.size.height
        // Sample only ink pixels at a fixed 1pt spacing, once per snapshot. Every
        // image tile chooses one of these origins through a stable GPU hash.
        for y in stride(from: CGFloat(0.5), to: snapshot.size.height, by: 1) {
            for x in stride(from: CGFloat(0.5), to: snapshot.size.width, by: 1) {
                let px = min(width - 1, Int(x * scaleX))
                let py = min(height - 1, Int(y * scaleY))
                if bytes[(py * width + px) * 4 + 3] > 40 {
                    glyphs.append(SIMD4(Float(x), Float(y), Float(x / snapshot.size.width), Float(y / snapshot.size.height)))
                }
            }
        }
        // Empty text still has a valid origin; never index an empty GPU buffer.
        if glyphs.isEmpty {
            glyphs.append(SIMD4(Float(snapshot.size.width / 2), Float(snapshot.size.height / 2), 0.5, 0.5))
        }
        let buffer = glyphs.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        guard let buffer else { throw DustRendererError.textureAllocation }
        glyphBuffer = buffer
        glyphCount = glyphs.count
        texture = newTexture
        contentSize = snapshot.size
        snapshotID = snapshot.id
    }

    func setTargetImage(_ image: CGImage) throws {
        targetTexture = try makeTexture(image).0
    }

    private func makeTexture(_ image: CGImage) throws -> (MTLTexture, [UInt8]) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        // Explicit byte format and top-left origin avoid MTKTextureLoader's
        // image-orientation / color-space ambiguity for transparent text.
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                              CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // CGImage's first bitmap row is already the top image row. An extra
            // UIKit-style Y flip here would upload upside-down text to Metal.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw DustRendererError.textureAllocation }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let newTexture = device.makeTexture(descriptor: descriptor) else {
            throw DustRendererError.textureAllocation
        }
        bytes.withUnsafeBytes { raw in
            newTexture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                               withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return (newTexture, bytes)
    }

    func encode(into encoder: MTLRenderCommandEncoder, viewport: CGSize) {
        guard let texture, viewport.width > 0, viewport.height > 0 else { return }
        let isMorph = mode == .textToImage && targetTexture != nil && !targetFrame.isEmpty
        var textOpacity: Float = isMorph ? max(0, 1 - max(0, time - 0.10) / 0.45) : 1
        let cell = max(0.65, particleSize)
        let columns = max(1, UInt32(ceil(contentSize.width / cell)))
        let rows = max(1, UInt32(ceil(contentSize.height / cell)))
        var uniforms = DustUniforms(
            viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
            origin: SIMD2(Float(origin.x), Float(origin.y)),
            contentSize: SIMD2(Float(contentSize.width), Float(contentSize.height)),
            // Keep only the first tiny breakup of the legacy effect. The morph
            // choreography itself has no leftward wind or edge clamping.
            grid: SIMD2(columns, rows), time: isMorph ? min(time, 0.16) : time, seed: 23
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DustUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&textOpacity, length: MemoryLayout<Float>.size, index: 0)
        if textOpacity > 0 {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: Int(columns * rows))
        }
        if isMorph { encodeMorph(into: encoder, viewport: viewport) }
    }

    private func encodeMorph(into encoder: MTLRenderCommandEncoder, viewport: CGSize) {
        guard let texture, let targetTexture, let glyphBuffer else { return }
        let cell = max(0.85, particleSize)
        let columns = max(1, UInt32(ceil(targetFrame.width / cell)))
        let rows = max(1, UInt32(ceil(targetFrame.height / cell)))
        var uniforms = MorphUniforms(
            viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
            sourceOrigin: SIMD2(Float(origin.x), Float(origin.y)),
            sourceSize: SIMD2(Float(contentSize.width), Float(contentSize.height)),
            targetOrigin: SIMD2(Float(targetFrame.minX), Float(targetFrame.minY)),
            targetSize: SIMD2(Float(targetFrame.width), Float(targetFrame.height)),
            grid: SIMD2(columns, rows), time: time, sourceCount: UInt32(glyphCount),
            cornerRadius: targetCornerRadius,
            loadingStart: Float(MorphTimeline.standard.loadingStart),
            loadingEnd: Float(MorphTimeline.standard.loadingEnd),
            formationEnd: Float(MorphTimeline.standard.formationEnd)
        )
        encoder.setRenderPipelineState(morphPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MorphUniforms>.stride, index: 0)
        encoder.setVertexBuffer(glyphBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(targetTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: Int(columns * rows))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(into: encoder, viewport: view.bounds.size)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

struct DustMetalView: UIViewRepresentable {
    let renderer: DustRenderer
    let origin: CGPoint
    let time: Double
    let particleSize: CGFloat
    var mode: DustEffectMode = .dissolve
    var targetFrame = CGRect.zero

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = renderer
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        renderer.origin = origin
        renderer.time = Float(time)
        renderer.particleSize = particleSize
        renderer.mode = mode
        renderer.targetFrame = targetFrame
        view.setNeedsDisplay()
    }

    static func dismantleUIView(_ view: MTKView, coordinator: ()) {
        view.delegate = nil
        view.isPaused = true
    }
}
