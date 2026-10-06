import SwiftUI

private let ink = Color(red: 0.12, green: 0.16, blue: 0.21)
private let quiet = Color(red: 0.51, green: 0.56, blue: 0.62)
private let blue = Color(red: 0.14, green: 0.54, blue: 0.92)

struct ContentView: View {
    @StateObject private var playback = DustPlayback()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false
    @State private var showInfo = false
    @State private var fineParticles = true
    @State private var mode: DustEffectMode = .textToImage

    private var status: String {
        if playback.isFinished { return mode == .textToImage ? "图片已呈现" : "已消散" }
        if playback.isPlaying {
            if mode == .dissolve { return "消散中" }
            let timeline = reduceMotion ? MorphTimeline.reducedMotion : .standard
            if playback.time < timeline.loadingStart { return "汇聚为圆环" }
            if timeline.isLoading(at: playback.time) { return "模拟生图中" }
            return "散开并成像"
        }
        if playback.time > 0 { return "已暂停" }
        return "准备就绪"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                introduction.padding(.top, 16)
                Picker("效果模式", selection: $mode) {
                    ForEach(DustEffectMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.top, 14)
                .accessibilityIdentifier("modePicker")
                DustStage(playback: playback, fineParticles: fineParticles,
                          reduceMotion: reduceMotion, mode: mode, isReady: $isReady)
                    .padding(.top, 8)

                HStack(spacing: 6) {
                    Circle().fill(playback.isPlaying ? blue : quiet.opacity(0.6))
                        .frame(width: 5, height: 5)
                    Text(status).accessibilityIdentifier("playbackStatus")
                    Text("·").padding(.horizontal, 2)
                    Text(mode == .textToImage ? "文字 → 等待 2 秒 → 画面" : "拖动进度，观察每一粒尘埃")
                }
                .font(.system(size: 11))
                .foregroundStyle(quiet)
                .padding(.top, 3)

                controls.padding(.top, 16)
                Text(mode == .textToImage ? "AI 预生成示例图 · 本地演示转换动画" : "轻触删除，让文字完成最后一次旅行。")
                    .font(.system(size: 11))
                    .foregroundStyle(quiet.opacity(0.85))
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 26)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.966, green: 0.975, blue: 0.982).ignoresSafeArea())
        .foregroundStyle(ink)
        .tint(blue)
        .sheet(isPresented: $showInfo) { sourceInfo }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.pause() }
        }
        .onChange(of: reduceMotion) { _, enabled in playback.reset(mode: mode, reduceMotion: enabled) }
        .onChange(of: mode) { _, selected in
            playback.reset(mode: selected, reduceMotion: reduceMotion)
        }
        .onDisappear { playback.pause() }
        .task(id: isReady) {
            #if DEBUG
            if isReady && ProcessInfo.processInfo.arguments.contains("--autoplay") {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                playback.speed = 1
                playback.play(mode: mode, reduceMotion: reduceMotion)
            }
            #endif
        }
        .onAppear {
            playback.reset(mode: mode, reduceMotion: reduceMotion)
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--preview-progress"),
               arguments.indices.contains(index + 1),
               let progress = Double(arguments[index + 1]) {
                playback.seek(to: progress)
            }
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(blue).frame(width: 40, height: 40)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                    .rotationEffect(.degrees(-8))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("让文字成像").font(.system(size: 16, weight: .semibold))
                Text("SWIFTUI  /  PARTICLE MORPH")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.2).foregroundStyle(quiet)
            }
            Spacer()
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 19))
                    .foregroundStyle(quiet).frame(width: 44, height: 44)
            }
            .accessibilityLabel("实现与源码参考")
        }
        .padding(.top, 12)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .textToImage ? "把想象，变成画面。" : "一次轻盈的告别。")
                .font(.system(size: 29, weight: .semibold)).tracking(-0.6)
            Text(mode == .textToImage ? "化作居中的圆环，等待两秒，再散开成像。" : "文字变成尘埃，沿着风的方向消失。")
                .font(.system(size: 13)).foregroundStyle(quiet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                HStack {
                    Text("动画进度").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(String(format: "%03d", Int((playback.progress * 100).rounded())) + "%")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(quiet)
                        .accessibilityIdentifier("progressValue")
                }
                Slider(value: Binding(get: { playback.progress }, set: { playback.seek(to: $0) }),
                       in: 0...1)
                    .accessibilityLabel("动画进度")
                    .accessibilityIdentifier("progressSlider")
                    .disabled(!isReady)
            }

            HStack {
                HStack(spacing: 0) {
                    speedButton("1×", speed: 1)
                    speedButton("0.25×", speed: 0.25)
                }
                .padding(3)
                .background(quiet.opacity(0.08), in: Capsule())
                Spacer()
                Button {
                    fineParticles.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.dotted")
                        Text(fineParticles ? "细腻颗粒" : "清晰颗粒")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(quiet)
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("grainButton")
            }

            HStack(spacing: 12) {
                Button {
                    if playback.isPlaying { playback.pause() }
                    else { playback.play(mode: mode, reduceMotion: reduceMotion) }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: playback.isPlaying ? "pause.fill" :
                                (playback.time > 0 ? "play.fill" : (mode == .textToImage ? "sparkles" : "trash")))
                        Text(playback.isPlaying ? "暂停动画" :
                                (playback.isFinished ? "再次播放" :
                                    (playback.time > 0 ? "继续动画" : (mode == .textToImage ? "文字化作图片" : "删除消息"))))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .foregroundStyle(.white)
                    .background(blue, in: RoundedRectangle(cornerRadius: 17))
                }
                .accessibilityIdentifier("playButton")
                .disabled(!isReady)

                Button { playback.reset(mode: mode, reduceMotion: reduceMotion) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 54, height: 54)
                        .background(.white, in: RoundedRectangle(cornerRadius: 17))
                        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(quiet.opacity(0.13)))
                }
                .accessibilityLabel("恢复文字")
                .accessibilityIdentifier("resetButton")
            }
            .buttonStyle(.plain)
        }
    }

    private func speedButton(_ title: String, speed: Double) -> some View {
        Button { playback.speed = speed } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(playback.speed == speed ? ink : quiet)
                .frame(width: 65, height: 32)
                .background {
                    if playback.speed == speed {
                        Capsule().fill(.white).shadow(color: .black.opacity(0.04), radius: 3, y: 1)
                    }
                }
        }
        .accessibilityLabel(speed == 1 ? "正常速度" : "四分之一慢速")
        .accessibilityAddTraits(playback.speed == speed ? .isSelected : [])
    }

    private var sourceInfo: some View {
        NavigationStack {
            List {
                Section("效果原理") {
                    Text("将 SwiftUI 文字渲染成透明纹理，再划分成约 1pt 的小片。Metal 并行计算每片的位移和透明度，从左向右启动，向上飘散。")
                    Text("成像模式中，文字颗粒先汇聚为居中的旋转圆环。完整 loading 持续两秒后，圆环向四周散开，再汇聚成图片。所有路径围绕画面中心计算，不再把越界粒子挤到左边界。")
                    Text("使用连续时间公式，可以暂停、慢放和来回拖动。系统开启“减弱动态效果”时使用淡化与静态等待标记，仍保留两秒等待。")
                }
                Section("这张测试图") {
                    Text("云海中的漂浮小岛、橙色小屋和圆树，晨光下的粉色群山。由 imagegen 生成并随应用打包。")
                    Text("本 demo 演示预生成图片的转换动画，不调用在线生图服务。接入服务后，可在收到图片时启动汇聚阶段。")
                }
                Section("Telegram iOS 源码参考") {
                    Link("DustEffectLayer.swift ↗", destination: sourceURL("Sources/DustEffectLayer.swift"))
                    Link("DustEffectShaders.metal ↗", destination: sourceURL("Metal/DustEffectShaders.metal"))
                    Text("基于源码思路独立实现，无 Telegram 依赖。具体对应关系见项目 README。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("关于消散效果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showInfo = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func sourceURL(_ suffix: String) -> URL {
        URL(string: "https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/DustEffect/" + suffix)!
    }
}

private struct MessageText: View {
    let width: CGFloat
    let fontSize: CGFloat
    let mode: DustEffectMode

    var body: some View {
        Text(mode == .textToImage
             ? "云海上的漂浮小岛，\n一间橙色小屋，一棵圆树。\n\n晨光洒落，粉色群山。\n像一场温柔的梦。"
             : "有些话，\n就让它随风散去。\n\n化作细小的尘埃，\n慢慢消失在空气里。")
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(ink)
            .lineSpacing(9)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SnapshotKey: Hashable {
    let width: CGFloat
    let fontSize: CGFloat
    let scale: CGFloat
    let mode: DustEffectMode
}

private struct DustStage: View {
    @ObservedObject var playback: DustPlayback
    let fineParticles: Bool
    let reduceMotion: Bool
    let mode: DustEffectMode
    @Binding var isReady: Bool
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .title2) private var fontSize = 21.0
    @State private var snapshot: DustSnapshot?
    @State private var renderer: DustRenderer?
    @State private var renderingError: String?

    private var stageHeight: CGFloat {
        max(mode == .textToImage ? (snapshot?.size.width ?? 302) + 60 : 350,
            (snapshot?.size.height ?? 190) + 140)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(120, geometry.size.width - 48)
            let textHeight = snapshot?.size.height ?? 190
            let origin = CGPoint(x: (geometry.size.width - width) / 2, y: 80)
            let key = SnapshotKey(width: width, fontSize: fontSize, scale: displayScale, mode: mode)
            let side = geometry.size.width - 4
            let targetFrame = CGRect(x: 2, y: (geometry.size.height - side) / 2, width: side, height: side)
            let fallback = reduceMotion || renderer == nil
            let timeline = reduceMotion ? MorphTimeline.reducedMotion : .standard
            let fallbackTextOpacity = mode == .textToImage
                ? timeline.textOpacity(at: playback.time) : max(0, 1 - playback.progress)
            let shellOpacity = playback.time == 0 ? 1.0 : max(0, 1 - playback.time / 0.9)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 25)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(ink.opacity(0.09), lineWidth: 1))
                    .shadow(color: ink.opacity(0.025), radius: 12, y: 8)
                    .frame(width: width + 44, height: textHeight + 76)
                    .offset(x: origin.x - 22, y: origin.y - 24)
                    .opacity(fallback ? fallbackTextOpacity : shellOpacity)

                MessageText(width: width, fontSize: fontSize, mode: mode)
                    .offset(x: origin.x, y: origin.y)
                    .opacity(playback.time == 0 ? 1 : (fallback ? fallbackTextOpacity : 0))
                    .accessibilityHidden(playback.time > 0)

                HStack(spacing: 4) {
                    Text("09:41")
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(quiet.opacity(0.8))
                .frame(width: width, alignment: .trailing)
                .offset(x: origin.x, y: origin.y + textHeight + 19)
                .opacity(fallback ? fallbackTextOpacity : shellOpacity)

                if fallback && mode == .textToImage {
                    Image("GeneratedArtwork")
                        .resizable().scaledToFill()
                        .frame(width: targetFrame.width, height: targetFrame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .offset(x: targetFrame.minX, y: targetFrame.minY)
                        .opacity(timeline.imageOpacity(at: playback.time))
                        .accessibilityHidden(true)
                }

                if let renderer, snapshot != nil, !reduceMotion, playback.time > 0 {
                    DustMetalView(renderer: renderer, origin: origin,
                                  time: playback.time, particleSize: fineParticles ? 0.85 : 1.5,
                                  mode: mode, targetFrame: targetFrame)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if mode == .textToImage && timeline.isLoading(at: playback.time) {
                    if fallback {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 62, weight: .light))
                            .foregroundStyle(blue)
                            .position(x: targetFrame.midX, y: targetFrame.midY)
                            .accessibilityHidden(true)
                    }
                    Text("正在生成图片…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(quiet)
                        .position(x: targetFrame.midX, y: targetFrame.midY + 80)
                        .accessibilityIdentifier("loadingIndicator")
                }

                if playback.isFinished && mode == .dissolve {
                    VStack(spacing: 10) {
                        Image(systemName: "wind").font(.system(size: 28, weight: .ultraLight))
                        Text("已随风散去").font(.system(size: 12))
                    }
                    .foregroundStyle(quiet.opacity(0.65))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if playback.isFinished && mode == .textToImage {
                    Color.clear.frame(width: targetFrame.width, height: targetFrame.height)
                        .offset(x: targetFrame.minX, y: targetFrame.minY)
                        .accessibilityElement()
                        .accessibilityLabel("生成的图片：云海上的漂浮小岛，橙色小屋与圆树，晨光下的粉色群山")
                        .accessibilityIdentifier("generatedArtwork")
                        .accessibilityAddTraits(.isImage)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onLongPressGesture {
                guard isReady else { return }
                playback.play(mode: mode, reduceMotion: reduceMotion)
            }
            .task(id: key) { prepareSnapshot(key) }
        }
        .frame(height: stageHeight)
        .overlay(alignment: .bottom) {
            if let renderingError {
                Text("已使用淡化效果：" + renderingError)
                    .font(.caption2).foregroundStyle(quiet)
            } else if reduceMotion {
                Text("减弱动态效果已开启 · 使用淡化")
                    .font(.caption2).foregroundStyle(quiet)
            }
        }
    }

    @MainActor
    private func prepareSnapshot(_ key: SnapshotKey) {
        isReady = false
        let imageRenderer = ImageRenderer(content: MessageText(width: key.width, fontSize: key.fontSize, mode: key.mode))
        imageRenderer.scale = key.scale
        guard let image = imageRenderer.cgImage else {
            renderingError = "无法生成文字快照"
            renderer = nil
            isReady = true
            return
        }
        let captured = DustSnapshot(image: image, size: CGSize(width: CGFloat(image.width) / key.scale,
                                                               height: CGFloat(image.height) / key.scale))
        snapshot = captured
        do {
            let engine = try renderer ?? DustRenderer()
            try engine.setSnapshot(captured)
            if key.mode == .textToImage {
                guard let artwork = UIImage(named: "GeneratedArtwork")?.cgImage else {
                    renderingError = "缺少示例图片，请检查 Assets"
                    renderer = nil
                    isReady = false
                    return
                }
                try engine.setTargetImage(artwork)
            }
            renderer = engine
            renderingError = nil
        } catch {
            renderer = nil
            renderingError = error.localizedDescription
        }
        isReady = true
    }
}

#Preview { ContentView() }
