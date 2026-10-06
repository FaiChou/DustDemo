# SwiftUI 文字 → 粒子 Loading → 图片 Demo

一个可直接用 Xcode 打开的 iOS demo：文字碎成颗粒，汇聚成居中的旋转 loading 圆环；完整等待两秒，再向四周散开并组合成图片。保留“删除消散”模式用于对比。界面使用 SwiftUI，粒子使用 Metal；不依赖 Telegram 的工程或第三方库。

## 新增：文字化作图片

默认选择“文字 → 图片”，点“文字化作图片”播放。支持 0.25× 慢放、暂停、任意进度拖动、恢复文字和重播。正常模式共 6 秒，其中完整 loading 持续 2 秒；慢放会同步放慢所有阶段。切换至“删除消散”可体验原来的 2.35 秒消失动画。

| 时间（1×） | 画面 |
| --- | --- |
| 0–1.4s | 文字颗粒向中心收拢，形成圆环 |
| 1.4–3.4s | 完整粒子圆环旋转，模拟 2 秒生图等待 |
| 3.4–4.0s | 圆环向四周散开，形成中心对称的粒子云 |
| 4.0–5.8s | 粒子染上图片颜色并拼成完整画面 |
| 6.0s | 动画停止，图片保留 |

原来的左侧竖条来自对越界粒子使用 `clamp`，导致很多横坐标被压到相同边界。新版成像路径完全移除了这种坐标钳制和向左漂移：圆环、扩散圆盘都以目标图片中心为中心，通过区域内部的位置插值移动，不再把粒子压在边缘。

测试图片已使用内置 **imagegen** 生成（2026-10-06），题材是“云海中的漂浮小岛、橙色小屋和圆树、晨光中的粉色群山”。图片已内置在 `DustDemo/Assets.xcassets/GeneratedArtwork.imageset/floating-cabin.png`，完整生成提示词保存在 `image-generation-prompt.txt`。

应用播放的是预生成图片的转换动画，loading 是固定两秒的本地模拟，不调用在线 AI 生图服务。接入服务时，可让圆环阶段循环到图片请求完成，再启动散开与汇聚；此 demo 不包括请求接口或鉴权。

新增渲染过程：

1. 快照文字，在约 1pt 的网格中按 alpha 采样，只选有笔画的点作为起点。
2. 保留短暂的文字碎片层作为交接。图片小片通过稳定随机映射选取笔画起点，从这些位置向画面中心汇聚。
3. 完整环形阶段仅保留约 2400 个代表粒子，避免几十万个小片叠成色块。圆环具有缺口和亮度渐变，旋转两秒。
4. 等待结束后，粒子从圆环释放到中心对称的圆盘，再插值到各自的目标像素；5.8 秒全部归位。

两组粒子在交接时同时存在，不要求文字笔画数量与图片像素数量相等。连续时间公式保证来回拖动是确定的。最终图片由纹理小片拼成，没有叠加一张静态图片来代替汇聚。圆角在目标 UV 中计算，保证归位后边界整齐。减少动态效果时缩短两端的淡化过渡，使用静态等待标记，但仍保留完整两秒等待；Metal 初始化失败时也使用淡化与等待标记。

## 运行

1. 打开 `DustDemo.xcodeproj`。
2. 选择 `DustDemo` scheme 和 iPhone 模拟器，按 ⌘R。
3. 点“文字化作图片”，或长按文字。可切换 0.25× 慢放、暂停、拖动进度、调整颗粒大小、恢复和重播；顶部可切换回删除消散。

最低 iOS 17，使用支持 iOS 17 SDK 的 Xcode。真机运行时在 Signing & Capabilities 中选择自己的 Team，并按需修改 Bundle Identifier。项目没有网络请求或安装依赖步骤。

工程文件已经生成，运行不需要 XcodeGen。修改工程结构时，可在这个目录执行 `xcodegen generate`，配置来源是 `project.yml`。

## 实际查询的 Telegram 源码

查询日期：2026-10-03。固定参考提交：`6ad963e5b62d354da79040f388ae2b9132fb17b8`。

| Telegram 文件 | 参考的机制 | Demo 对应 |
| --- | --- | --- |
| [ChatHistoryListNode.swift](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Sources/ChatHistoryListNode.swift#L3978-L4005) | `makeContentSnapshot()` 后交给消散图层，隐藏原消息 | `ContentView.swift` 中的 `prepareSnapshot` 与文字/粒子图层切换 |
| [DustEffectLayer.swift](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/DustEffect/Sources/DustEffectLayer.swift) | 快照纹理、按消息 point 尺寸建立网格、GPU 批量绘制 | `Effect/DustMetalView.swift` |
| [DustEffectShaders.metal](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/DustEffect/Metal/DustEffectShaders.metal) | 左到右的启动窗口、随机初速度、寿命、加速度和末尾透明度衰减 | `Effect/DustShaders.metal` |

这是参考上述算法结构后的独立 demo 实现，不是把 Telegram 的 `DustEffectLayer` 直接移植过来。没有复制其 MetalEngine、SharedDisplayLinkDriver 或 Loki 随机数库。

## 原消散模式与 Telegram 的对应

1. **快照真实文字。** `ImageRenderer` 以屏幕 scale 将 SwiftUI `MessageText` 渲染为透明 CGImage，保留抗锯齿和字形。布局与截图复用同一个 View。
2. **切成纹理小片。** 每片约 0.85pt（细腻）或 1.5pt（清晰），通过 instanced triangle strip 一次绘制。每个小片采样原图对应的区域，透明区域仍透明；不是用随机黑点覆盖原字。
3. **按横坐标启动。** 沿用 Telegram 的 0.8 秒扫过窗口思路。越靠左的粒子越早运动。
4. **飘散并淡出。** 初速度范围 42–84pt/s，随机寿命 0.7–1.5 秒，末尾 0.3 秒淡出。Y 轴朝上加速；额外加入轻微向左的风，让方向接近参考图。
5. **粒子状态可回放。** Telegram 用 compute kernel 逐帧积分并保存状态；本 demo 在 vertex shader 中对启动窗口作解析积分，直接由时间求出位移和寿命。因此拖回某个进度时，能准确回到同一帧，也不依赖屏幕刷新率。
6. **气泡单独淡出。** 截图只包含文字。白色气泡和时间戳单独淡出，以突出字形颗粒。Telegram 则把消息的 content snapshot 交给效果层，覆盖范围取决于消息节点的快照。

设 `a` 是启动权重的时间积分，粒子运动使用 `p = p₀ + v₀a + ½ga²`。未启动时 `a = 0`，小片完整拼回原文字；寿命结束后完全透明。总时间为 2.35 秒，0.25× 慢放约 9.4 秒。

Metal 视图通过 `UIViewRepresentable` 嵌入 SwiftUI。暂停时停止 `CADisplayLink`，MTKView 仅按需绘制。进入后台暂停；系统启用“减弱动态效果”时，删除模式使用 0.3 秒淡出，成像模式使用短淡化和两秒静态等待。无法创建 Metal 管线或纹理时保留淡化行为，并显示原因。汇聚成图是本 demo 在原消散思路上的扩展，不是 Telegram 原源码中的成像功能。

## 文件

```text
DustDemo/
  DustDemoApp.swift              应用入口
  ContentView.swift              页面、快照、文字/粒子切换、源码说明
  Effect/
    DustPlayback.swift          MorphTimeline 共享阶段时间、播放/暂停/进度
    DustMetalView.swift         纹理上传、Metal 渲染、SwiftUI 桥接
    DustShaders.metal          消散、粒子圆环、中心扩散、图片重建
  Assets.xcassets/
    GeneratedArtwork.imageset/ AI 生成的测试图片
DustDemoTests/                  播放状态与离屏 GPU 图像测试
DustDemoUITests/                删除、恢复、拖动与慢放暂停测试
```

替换示例文字：修改 `MessageText` 中的 `Text`。替换成像图片：替换 `GeneratedArtwork` 的图片文件（当前演示使用正方形图片）。调整运动：修改 `DustShaders.metal`；阶段时长统一在 `MorphTimeline` 中设置，并传入 Metal uniforms，UI 与着色器使用同一时间表。

此项目聚焦单条消息的视觉演示。接入真实聊天列表时，应将效果叠在列表之上，先记录消息在叠层中的位置和快照，再删除数据，并在粒子结束后移除叠层。

## 验证

2026-10-06 Loading 版已在 Xcode 27.0 / iPhone 18 Pro（iOS 27.0）模拟器编译运行，6 个单元/GPU 测试和 3 个界面测试全部通过。新增回归检查专门验证：完整环形持续两秒、圆环居中且空心、左/右边界无粒子竖条、散开阶段左右 alpha 总量接近、等待结束前不显示图片，以及暂停/拖动 loading 后仍能完成成像。此前的纹理重建、圆角、空文字起点和模式切换测试也继续通过。代码复审通过。尚未在实体 iPhone 上测量帧率或功耗。

在 Xcode 用 ⌘U 运行测试，或：

```sh
xcodebuild -project DustDemo.xcodeproj -scheme DustDemo \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

将模拟器名称替换成本机可用设备。GPU 测试验证纹理上下方向、原图重建、粒子离开原范围、前后拖动的确定性，以及结束时全部透明。播放测试还验证减弱动态效果切回正常模式后，拖到 100% 使用正确的完整时间轴。

Debug 构建支持启动参数 `--preview-progress 0.4`，便于截图检查完整 loading；`--autoplay` 会在准备完成后自动以 1× 速度播放，用于录屏。正式 Release 构建不读取这些参数。
