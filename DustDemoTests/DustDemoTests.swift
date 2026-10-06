import XCTest
import MetalKit
@testable import DustDemo

@MainActor
final class DustDemoTests: XCTestCase {
    func testPauseSeekReplayAndReducedMotion() {
        let clock = DustPlayback()
        clock.speed = 0.25
        clock.play()
        clock.advance(by: 1)
        XCTAssertEqual(clock.time, 0.25, accuracy: 0.0001)
        clock.pause()
        clock.advance(by: 1)
        XCTAssertEqual(clock.time, 0.25, accuracy: 0.0001)
        clock.seek(to: 1.5)
        XCTAssertTrue(clock.isFinished)
        clock.play()
        XCTAssertEqual(clock.time, 0)
        clock.reset()
        XCTAssertFalse(clock.isPlaying)
        XCTAssertEqual(clock.progress, 0)
        clock.play(reduceMotion: true)
        XCTAssertEqual(clock.duration, 0.3)
        clock.advance(by: 2)
        XCTAssertTrue(clock.isFinished)
        XCTAssertFalse(clock.isPlaying)
        clock.seek(to: .nan)
        XCTAssertTrue(clock.time.isFinite)
        // Switching back from reduced motion must restore the full GPU timeline,
        // including before pressing Play (the slider is usable immediately).
        clock.reset(reduceMotion: false)
        clock.seek(to: 1)
        XCTAssertEqual(clock.time, DustPlayback.particleDuration)
        clock.reset(reduceMotion: true)
        clock.seek(to: 1)
        XCTAssertEqual(clock.time, 0.3)
        clock.reset()
    }

    func testMorphModeDurationAndModeSwitching() {
        let clock = DustPlayback()
        clock.reset(mode: .textToImage)
        clock.seek(to: 1)
        XCTAssertEqual(clock.time, 6.0)
        clock.play(mode: .textToImage)
        XCTAssertEqual(clock.time, 0)
        clock.advance(by: 1.5)
        clock.reset(mode: .dissolve)
        XCTAssertEqual(clock.duration, 2.35)
        XCTAssertFalse(clock.isPlaying)
        clock.reset(mode: .textToImage, reduceMotion: true)
        XCTAssertEqual(clock.duration, MorphTimeline.reducedMotion.duration)
        clock.reset(mode: .textToImage)
        clock.seek(to: 1)
        XCTAssertEqual(clock.time, 6.0)
        clock.reset()
    }

    func testLoadingHoldsForTwoSecondsAndDoesNotRevealImageEarly() {
        for timeline in [MorphTimeline.standard, .reducedMotion] {
            XCTAssertEqual(timeline.loadingEnd - timeline.loadingStart, 2, accuracy: 0.00001)
            XCTAssertFalse(timeline.isLoading(at: timeline.loadingStart - 0.001))
            XCTAssertTrue(timeline.isLoading(at: timeline.loadingStart))
            XCTAssertTrue(timeline.isLoading(at: timeline.loadingEnd - 0.001))
            XCTAssertFalse(timeline.isLoading(at: timeline.loadingEnd))
            XCTAssertEqual(timeline.imageOpacity(at: timeline.loadingEnd), 0)
            XCTAssertEqual(timeline.textOpacity(at: timeline.loadingStart), 0)
            XCTAssertEqual(timeline.imageOpacity(at: timeline.duration), 1)
        }
        let clock = DustPlayback()
        clock.play(mode: .textToImage)
        clock.advance(by: 1.4)
        clock.pause()
        clock.advance(by: 2)
        XCTAssertEqual(clock.time, 1.4)
        clock.play(mode: .textToImage)
        clock.advance(by: 1.999)
        XCTAssertTrue(MorphTimeline.standard.isLoading(at: clock.time))
        clock.advance(by: 0.002)
        XCTAssertFalse(MorphTimeline.standard.isLoading(at: clock.time))
        clock.reset()
    }

    func testLoadingRingIsCenteredHollowAndHasNoEdgeStripe() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable") }
        let renderer = try DustRenderer()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let source = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 128), format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 128))
            ctx.fill(CGRect(x: 0, y: 64, width: 64, height: 8))
        }
        let target = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try renderer.setSnapshot(DustSnapshot(image: try XCTUnwrap(source.cgImage), size: source.size))
        try renderer.setTargetImage(try XCTUnwrap(target.cgImage))
        // Deliberately left-heavy text: the old clamped cloud produced a stripe.
        renderer.origin = CGPoint(x: 12, y: 60)
        renderer.targetFrame = CGRect(x: 8, y: 8, width: 240, height: 240)
        renderer.mode = .textToImage
        let first = try render(renderer, time: 1.4)
        for time: Float in [1.4, 2.1, 2.8, 3.399] {
            let pixels = try render(renderer, time: time)
            var mass = 0.0, weightedX = 0.0, weightedY = 0.0
            var edgeAlpha = 0, centerAlpha = 0, outsideRingAlpha = 0
            for y in 0..<256 {
                for x in 0..<256 {
                    let alpha = Int(pixels[(y * 256 + x) * 4 + 3])
                    mass += Double(alpha)
                    weightedX += Double(alpha * x)
                    weightedY += Double(alpha * y)
                    let radius = hypot(Double(x) + 0.5 - 128, Double(y) + 0.5 - 128)
                    if x < 20 || x >= 236 || y < 20 || y >= 236 { edgeAlpha += alpha }
                    if radius < 28 { centerAlpha += alpha }
                    if radius > 44 { outsideRingAlpha += alpha }
                }
            }
            XCTAssertGreaterThan(mass, 20_000)
            XCTAssertEqual(edgeAlpha, 0, "No stripe or particles may stick to the boundary")
            XCTAssertEqual(centerAlpha, 0, "Loading must be a hollow ring, not a central blob")
            XCTAssertEqual(outsideRingAlpha, 0, "For the full 2s all visible particles must be on the ring")
            XCTAssertEqual(weightedX / mass, 128, accuracy: 15)
            XCTAssertEqual(weightedY / mass, 128, accuracy: 15)
        }
        XCTAssertNotEqual(try render(renderer, time: 1.8), first, "The loading ring must rotate")
        let burst = try render(renderer, time: 4.0)
        var left = 0, right = 0, stripe = 0
        for y in 0..<256 {
            for x in 0..<256 {
                let alpha = Int(burst[(y * 256 + x) * 4 + 3])
                if x < 128 { left += alpha } else { right += alpha }
                if x < 20 || x >= 236 { stripe += alpha }
            }
        }
        XCTAssertEqual(stripe, 0)
        XCTAssertLessThan(abs(Double(left - right)) / Double(left + right), 0.05,
                          "The release cloud must spread equally left and right")
    }

    func testMorphReconstructsTargetWithoutGapsAndSeeksDeterministically() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable") }
        let renderer = try DustRenderer()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let factory = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
        let source = factory.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 8, y: 4, width: 8, height: 52))
            ctx.fill(CGRect(x: 8, y: 32, width: 45, height: 8))
        }
        let target = factory.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 32, width: 32, height: 32))
            UIColor.yellow.setFill()
            ctx.fill(CGRect(x: 32, y: 32, width: 32, height: 32))
        }
        try renderer.setSnapshot(DustSnapshot(image: try XCTUnwrap(source.cgImage), size: source.size))
        try renderer.setTargetImage(try XCTUnwrap(target.cgImage))
        renderer.origin = CGPoint(x: 96, y: 112)
        renderer.targetFrame = CGRect(x: 96, y: 96, width: 64, height: 64)
        renderer.targetCornerRadius = 0
        XCTAssertGreaterThan(renderer.glyphCount, 400)
        XCTAssertEqual(MemoryLayout<MorphUniforms>.stride, 72)
        let original = try render(renderer, time: 0)
        renderer.mode = .textToImage
        XCTAssertEqual(try render(renderer, time: 0), original, "Morph must start at the original text")
        let traveling = try render(renderer, time: 1.8)
        _ = try render(renderer, time: 0.35)
        XCTAssertEqual(try render(renderer, time: 1.8), traveling)
        let end = try render(renderer, time: 6.0)
        XCTAssertNotEqual(traveling, end)
        XCTAssertGreaterThan(end[(100 * 256 + 100) * 4 + 2], 250) // top-left red
        XCTAssertGreaterThan(end[(100 * 256 + 150) * 4 + 1], 250) // top-right green
        XCTAssertGreaterThan(end[(150 * 256 + 100) * 4], 250)     // bottom-left blue
        XCTAssertEqual(alphaSum(end), 64 * 64 * 255, "Destination must be opaque and have no tile gaps")
        XCTAssertEqual(try render(renderer, time: 8), end, "The finished image must persist")
        renderer.targetCornerRadius = 12
        let rounded = try render(renderer, time: 6.0)
        XCTAssertEqual(rounded[(96 * 256 + 96) * 4 + 3], 0)
        XCTAssertEqual(rounded[(128 * 256 + 128) * 4 + 3], 255)
        let empty = factory.image { _ in }
        try renderer.setSnapshot(DustSnapshot(image: try XCTUnwrap(empty.cgImage), size: empty.size))
        XCTAssertEqual(renderer.glyphCount, 1)
        XCTAssertEqual(try render(renderer, time: 6.0), rounded)
    }

    func testMetalReconstructionOrientationDispersionAndDeterministicSeeking() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable") }
        let renderer = try DustRenderer()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let source = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 20))
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 40, y: 44, width: 24, height: 20))
        }
        try renderer.setSnapshot(DustSnapshot(image: try XCTUnwrap(source.cgImage), size: source.size))
        renderer.origin = CGPoint(x: 96, y: 112)
        renderer.particleSize = 1
        XCTAssertEqual(MemoryLayout<DustUniforms>.stride, 40)

        let start = try render(renderer, time: 0)
        // BGRA output, top-left red and bottom-right green; also checks texture orientation.
        XCTAssertGreaterThan(start[(118 * 256 + 102) * 4 + 2], 240)
        XCTAssertGreaterThan(start[(166 * 256 + 150) * 4 + 1], 240)
        XCTAssertEqual(start[(144 * 256 + 128) * 4 + 3], 0)
        XCTAssertGreaterThan(alphaSum(start), 200_000)

        let dispersed = try render(renderer, time: 0.85)
        XCTAssertNotEqual(dispersed, start)
        XCTAssertGreaterThan(alphaSum(dispersed), 0)
        var escapedAlpha = 0
        for y in 0..<256 {
            for x in 0..<256 where x < 96 || x >= 160 || y < 112 || y >= 176 {
                escapedAlpha += Int(dispersed[(y * 256 + x) * 4 + 3])
            }
        }
        XCTAssertGreaterThan(escapedAlpha, 1_000, "Particles must move outside the original content rect")
        _ = try render(renderer, time: 0.2)
        XCTAssertEqual(try render(renderer, time: 0.85), dispersed, "Seeking must be deterministic")
        XCTAssertEqual(alphaSum(try render(renderer, time: Float(DustPlayback.particleDuration))), 0)
    }

    private func alphaSum(_ bytes: [UInt8]) -> Int {
        stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
    }

    private func render(_ renderer: DustRenderer, time: Float) throws -> [UInt8] {
        renderer.time = time
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 256, height: 256, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        renderer.encode(into: encoder, viewport: CGSize(width: 256, height: 256))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, String(describing: command.error))
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: 256 * 4,
                             from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
        }
        return bytes
    }
}
