import QuartzCore
import SwiftUI

enum DustEffectMode: String, CaseIterable, Identifiable {
    case textToImage, dissolve
    var id: Self { self }
    var title: String { self == .textToImage ? "文字 → 图片" : "删除消散" }
    var duration: Double { self == .textToImage ? MorphTimeline.standard.duration : 2.35 }
}

/// All stages share this clock. The fully formed loading ring lasts exactly two
/// animation seconds, including when Reduce Motion shortens the transitions.
struct MorphTimeline {
    let loadingStart: Double
    let loadingEnd: Double
    let formationEnd: Double
    let duration: Double

    static let standard = MorphTimeline(loadingStart: 1.4, loadingEnd: 3.4,
                                       formationEnd: 5.8, duration: 6.0)
    static let reducedMotion = MorphTimeline(loadingStart: 0.18, loadingEnd: 2.18,
                                            formationEnd: 2.36, duration: 2.46)

    func isLoading(at time: Double) -> Bool { time >= loadingStart && time < loadingEnd }
    func textOpacity(at time: Double) -> Double { max(0, 1 - time / loadingStart) }
    func imageOpacity(at time: Double) -> Double {
        min(1, max(0, (time - loadingEnd) / (formationEnd - loadingEnd)))
    }
}

/// The clock is independent of the renderer. Pausing or seeking never regenerates particles.
@MainActor
final class DustPlayback: ObservableObject {
    static let particleDuration = 2.35

    @Published private(set) var time: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration = particleDuration
    @Published var speed: Double = 1

    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?

    var progress: Double { time / duration }
    var isFinished: Bool { time >= duration }

    func play(mode: DustEffectMode = .dissolve, reduceMotion: Bool = false) {
        let newDuration = durationFor(mode: mode, reduceMotion: reduceMotion)
        if isFinished || duration != newDuration { time = 0 }
        duration = newDuration
        guard !isPlaying else { return }
        isPlaying = true
        previousTimestamp = nil
        let proxy = DisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func pause() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
        isPlaying = false
    }

    func reset(mode: DustEffectMode = .dissolve, reduceMotion: Bool = false) {
        pause()
        duration = durationFor(mode: mode, reduceMotion: reduceMotion)
        time = 0
    }

    func seek(to progress: Double) {
        pause()
        guard progress.isFinite else { return }
        time = min(1, max(0, progress)) * duration
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let previous = previousTimestamp else {
            previousTimestamp = link.timestamp
            return
        }
        previousTimestamp = link.timestamp
        // A stalled frame must not jump the entire effect to its end.
        advance(by: min(max(link.timestamp - previous, 0), 1.0 / 15.0))
    }

    func advance(by delta: Double) {
        guard isPlaying, delta.isFinite, delta > 0 else { return }
        time = min(duration, time + delta * speed)
        if isFinished { pause() }
    }

    private func durationFor(mode: DustEffectMode, reduceMotion: Bool) -> Double {
        if mode == .textToImage {
            return (reduceMotion ? MorphTimeline.reducedMotion : .standard).duration
        }
        return reduceMotion ? 0.3 : mode.duration
    }

    deinit { displayLink?.invalidate() }
}

@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: DustPlayback?

    init(owner: DustPlayback) { self.owner = owner }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.tick(link)
    }
}
