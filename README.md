# 月读空间 · Flutter 原生客户端

Tsukuyomi Space 的独立 Flutter 客户端。0.6.30 移动网页体验对齐与官方八千代语音 / Live2D / 桌面 Agent 测试版提供原生 Room、统一认证、内容阅读与创作、社区、游戏和管理页面，直接连接原网站 API。

站内直供、原生支付中心、充值订单、用量账单及支付宝移动支付的开发同步与验收边界见 [站内直供与原生支付中心](docs/native-official-payments-2026-10-21.md)。移动应用的 App 支付采用独立服务端凭据，SDK 回调后由主站查单确认到账。

整站原生页面包含入口、Hub、Wiki、图库、附件库、编辑器、像素工坊、辉夜跑酷、友链、公开主页、管理后台和 Live2D 工作台，支持跨设备事件、中文／日语／英语、全站搜索及八千代导览。后台只向有效登录的 admin／super_admin 显示和开放；本地、合并与云端记忆来源跟进原站最新逻辑。实现与验收边界见 [整站迁移记录](docs/native-full-site-implementation-2026-09-30.md)。

下载安装包见 [GitHub Releases](https://github.com/redchenk/tsukuyomi-space-app/releases)，配置与安装说明见 [release-guide.md](docs/release-guide.md)。发布包包括 Android APK、macOS Universal DMG、Windows 安装程序、Linux DEB，以及供用户自签的 iOS IPA 和 HarmonyOS HAP。

所有平台打开即进入 Room，不播放 Access 动画。默认关闭演示；首次使用在聊天区填写模型地址、名称和 Key，保存后直接真实聊天。已有配置直接可用，本地历史先加载，登录与同步随后执行。升级保留独立演示历史。

Android 使用 Cubism 官方 OpenGL ES 渲染器和 Flutter 外部纹理；iOS/macOS、Windows、Linux 分别接入 Metal、D3D11 和 OpenGL。自动档使用 3K 图集，保留单帧限流、聊天交互期间动画和失败自动回退；设置中可切回 Canvas。HarmonyOS 继续使用 Canvas。实现与设备验收边界见 [原生 GPU 渲染](docs/native-live2d-gpu.md) 和 [跨平台适配](docs/native-live2d-platforms.md)。

0.6.20 将 Room 的 Live2D 绘制改为异步帧缓存和有界调度，减少交互时的绘制开销；修复辉夜快跑背景克隆闪烁和下车后的角色动画。保留输入法修复、2048纹理和鼠标追踪关闭。见 [Room 绘制与游戏验证](docs/native-room-pipeline-v0.6.20.md)。

0.6.17 优化 Room 聊天滚动：修复长回复逐字符重复扫描，缓存已完成回复与图片字节，关闭聊天 Markdown 的文章进度测量，流式更新避开拖动及惯性滚动。保持2048纹理和原有聊天分句、选区、链接、分享与朗读。见 [聊天滚动与复测记录](docs/native-chat-scroll-v0.6.17.md)。GitHub Release只展示当版更新，[历史日志](docs/changelog.md)单独保留。

0.6.16 移除 Room 与全屏角色舞台加载期间的静态立绘兜底，保留背景及简短状态；加载失败可重试，模型未就绪时仍可聊天。沿用2048纹理和更新弹窗，见 [加载体验修复记录](docs/native-room-loading-v0.6.16.md)。

0.6.15 修复窄屏导航品牌截断，新增自动更新弹窗；所有 Live2D 画质档限制为 2048 纹理，自动档降低绘制预算，待机动画不再逐帧重建外层控件。详见 [导航、更新与 Live2D 优化记录](docs/native-room-update-v0.6.15.md)。

0.6.14 修复辉夜快跑异常后无法重开、骑乘重开时碰撞图露出的问题；重开完整恢复原始状态并在首帧前完成重置，脚本异常展示可恢复提示。完整骑乘、下车、暂停、死亡与连续重开使用同一套 Android 原生绘制探针验证。见 [骑乘与重开修复记录](docs/native-game-riding-v0.6.14.md)。

0.6.13 提高手机和桌面 Room 的默认 Live2D 清晰度：使用 3072 纹理，绘制预算集中在角色区域，关闭鼠标追踪；保留省电、完整分辨率、自适应帧率与隐藏暂停。详见 [画质与验证记录](docs/native-live2d-clarity-v0.6.13.md)。0.6.12 的页面性能、全屏与游戏修复见 [修复说明](docs/native-pc-game-v0.6.12.md) 与 [性能对比](docs/native-performance-v0.6.12.md)。

0.6.11 加入应用内更新：顶部更新图标或菜单 → 应用更新，自动检查 GitHub 新版，展示说明，由用户下载、校验并打开系统安装器；支持取消、正式/预览渠道和稍后提醒。首次需手动安装 0.6.11 或更新版本，此后才能在应用内获取新版。macOS / Linux 使用系统安装包，iOS 仍需自签，详见 [应用内更新说明](docs/in-app-updates.md)。

0.6.10 同步网站近期导航纹饰、Hub 图片渐隐和公告，缩小足迹区字体；补齐当前服务商模型目录、参数与能力覆盖、新版角色知识和记忆数量、GitHub 原生认证。见 [0.6.10 同步与验收边界](docs/native-site-sync-v0.6.10.md)。

0.6.9 跟进网站四季配色与素材、分组导航、Room 昼夜背景和网易云音乐库。同步完整聊天轮次、重生成记忆校验、模型参数规则及游戏分页与连续轮回。见 [0.6.9 网站同步记录](docs/native-site-sync-v0.6.9.md)。

0.6.8 同步网站的月白樱粉配色、Material 组件、深浅背景、樱月导航与大厅插画；新安装默认浅色，保留已保存的主题。见 [UI 对齐说明](docs/native-ui-theme-v0.6.8.md)。

0.6.7 跟进网站的 AstrBot 分层设计，统一四类 LLM 的实时输出、私有状态续接、工具结果与 MCP 握手。协议核对和验证见 [原生 LLM / Agent 协议](docs/native-llm-agent-protocol-v0.6.7.md)。

0.6.6 补齐文章 Markdown 预览排版和登录头像，验证记录见 [预览与头像修复](docs/native-preview-avatar-v0.6.6.md)。

0.6.5 同步新版图库、个人中心、广场与文章导航，消除中枢无关状态重建，缓存像素预览并限制图片解码；截图、性能数据与验证边界见 [0.6.5 UI 与滑动验证](docs/native-ui-parity-v0.6.5.md)。

## 与网站一致的双端界面

Room 按 [现有网站](https://yachiyo.hk/room) 的桌面和手机版分别实现，复用夜景、背景与角色素材：

- **桌面（宽度 > 860）**：顶部导航、左侧角色舞台、右侧聊天工作区，包含聊天／Agent／日记／资料／便签标签、快捷话题和输入框。
- **移动端（宽度 ≤ 860）**：全屏角色场景，顶部悬浮导航与房间工具，底部叠加聊天和胶囊输入框；弹出键盘时输入框上移，保持场景完整。
- 聊天、历史搜索、新建会话、资料、本机便签、明暗主题、表情和安静陪伴可操作。图片聊天支持压缩、上传、历史回读和失败恢复；房间音乐支持曲目、进度、音量与播放控制。投稿编辑器、百科、图库、像素工坊和游戏均在应用内以 Flutter 页面打开。

房间中的「新建会话」会先确认清空；已登录时先清除网站聊天，再清除对应本机聊天与录制。需要留存时可先结束会话生成日记，或分享对话。便签需点击保存，仅存本机，与聊天草稿分开。

Room / Room settings 功能对照见 [docs/room-parity.md](docs/room-parity.md)，本版截图、验证尺寸和验收边界见 [design-qa.md](design-qa.md)。

## 环境与启动

本次开发使用 Flutter **3.47.5** / Dart **3.13.4**。平台项目包括 Android、iOS、macOS、Windows、Linux、Web。

```sh
flutter pub get
flutter run -d macos
```

首次克隆不包含 Cubism SDK 和角色模型，仍可运行界面和对话功能，角色区域会明确显示模型载入失败和重试入口。Web 仅作为界面预览，不提供 Cubism Native 或站点账号登录。

macOS 使用 Swift Package Manager；尚未支持 SwiftPM 的视频及 OAuth WebView 插件由 CocoaPods 集成，构建前需安装 CocoaPods。iOS 需要相应 Xcode SDK，Android 需要 Android SDK/NDK。Windows 和 Linux 在各自系统构建。

## 桌面 Agent

Windows/macOS/Linux 在 Room 的 Agent 标签选择工作目录并输入任务。安装包捆绑固定 OpenCode **1.18.33** 与 Codex **0.159.0**，首次使用才启动；普通聊天不依赖 CLI。模型、API 地址和 Key 复用 Room 配置，支持 Chat Completions、Responses、Anthropic 与 Ollama，也可选择严格结构化兼容模式。

文件、命令、MCP、文章草稿修改/撤销和发布统一经工具网关。越界、MCP 和服务器写入展示具体内容确认；命令仅在系统沙箱运行，默认 120 秒超时、20 次工具上限，缺失沙箱则停止。提权当前不支持。账号、站点或模型配置切换会取消任务和审批。恢复会话不会重放已完成操作。

开发环境先执行 `python3 tool/agent/prepare_runtime.py --target macos`（或 windows/linux）。桌面发布构建后执行 `package_runtime.py` 将运行时复制到安装目录；二进制不提交到 Git。SVG 生成及原站图标修复见 [0.6.3 验证](docs/native-svg-icons-v0.6.3.md)，DeepSeek 自动模式、实时输出及任务进度修复见 [0.6.2 验证](docs/native-agent-progress-v0.6.2.md)，文章预览与滚动修复见 [0.6.1 验证](docs/native-fixes-v0.6.1.md)，完整功能核对表和限制见 [0.6 验收](docs/native-room-agent-v0.6.md)。

## 启用真实 Live2D

1. 从 [Live2D 官方下载页](https://www.live2d.com/en/sdk/download/native/) 获取 **Cubism SDK for Native 5 R5**，阅读相应许可并解压。
2. 使用已有 tsukuyomi-space 仓库中的角色资源：

```sh
python3 tool/setup_live2d.py \
  --sdk /path/to/CubismSdkForNative-5-r.5 \
  --model ../tsukuyomi-space/models/tsukimi-yachiyo/tsukimi-yachiyo.model3.json
flutter clean
flutter pub get
flutter run -d macos
```

脚本仅复制文件到本项目，不修改来源。SDK 放在 `packages/tsukuyomi_live2d/vendor/cubism/`，模型放在 `assets/live2d/`，二者均被 Git 忽略。更改 SDK 是否存在后必须执行 `flutter clean`，使原生构建钩子重新检测。

加载成功后「角色状态」显示当前渲染方式、网格数量及模型更新耗时；GPU 路径另显示后端名称、输出尺寸、有效 DPR 与原生提交计时。它们**不代表 GPU 执行时间或实际帧率**。自动/细节优先目标为 60fps，省电为 30fps，持续负载下会降低帧率；离开页面、后台、最小化时暂停，输入交互时继续动画。支持眨眼、呼吸、物理、表情与音频口型，鼠标追踪保持关闭。

支持的平台默认采用 **Cubism Native Core + Framework + 官方 GPU Renderer → Flutter Texture**，不逐帧传出网格或进行 CPU 像素读回。HarmonyOS 和兼容模式采用 **Cubism Native + Flutter Canvas**；GPU 初始化或绘制失败时自动回退。没有 WebView 或 JavaScript 引擎。详见 [渲染架构和验证](docs/native-live2d-gpu.md)。

已支持普通/反向遮罩、标准加法/乘法混合、multiply/screen 色彩；明确拒绝 Cubism 5.3 的离屏部件和扩展混合。网站表情与动作预设通过原生参数和舞台变换执行，支持队列、动作过渡、回复情绪反应与设置页 JSON 调试。任意 Cubism motion3 动作文件播放仍未实现。

## 连接模型与语音

首次可在聊天区直接填写模型；完整配置在房间设置中填写：

- **模型 API 地址 / Base URL**：例如本机 `http://localhost:11434/v1/chat/completions`，或你的服务商提供的 HTTPS 地址。
- **模型名称**：填写该端点实际提供的模型 ID。
- **API Key**：只在服务需要时填写，不使用 GitHub 令牌。
- **语音回复**：可选。登录后可选择「官方直供 · 八千代语音」，使用网站余额，无需供应商密钥；也可选择其他服务，填写对应地址、模型、音色和独立密钥。

聊天支持 OpenAI 兼容 Chat Completions / Responses、Anthropic Messages、Ollama 和网站代理，处理 **SSE、NDJSON 和完整 JSON**。UTF-8 分片、CRLF、结束标记、超时、取消和截断均有测试。设置中的 MCP 支持 REST 桥接与 Streamable HTTP 握手。模型可在对话中按白名单调用搜索和当前图片理解，工具结果配对后继续流式回复；原有关键词预读保留兼容。未完成回复不写入历史，保留用户输入供重试。桌面 Enter 发送、Shift + Enter 换行，也支持 ⌘ Enter / Ctrl Enter；⌘ K / Ctrl K 打开本机历史搜索。移动端回车换行，点击按钮发送。

TTS 支持网站官方直供、OpenAI 兼容、MiMo、MiniMax、ElevenLabs、GPT-SoVITS 和网站代理，设置中可独立试听与停止。官方直供成功合成 ¥0.05/条，中文先通过当前聊天模型翻译为日语；状态、免合成保存、付费试听、会话缓存重播与语音账单见[接入说明](docs/native-official-tts-2026-10-23.md)。WAV/MP3 解码后分析真实 PCM 的 20ms RMS 音量包络，并与播放器时间对齐控制口型；仅解码不可用时采用降级包络。真实供应商音色与音素级口型仍需验收。语音失败不撤销已保存的文字对话。

远程服务要求 HTTPS；HTTP 仅用于 localhost/回环地址及 Android 模拟器主机 `10.0.2.2`。手机上的 localhost 指手机自身，不能直接访问电脑的 Ollama。原生应用的网络访问仍受各平台网络权限约束。

## 登录与同步

设置中的站点默认 `https://yachiyo.hk`。支持用户名/邮箱 + 密码、邮箱验证码、注册和密码重设。QQ OAuth 的第三方授权页通过系统 WebView 打开，账号创建、绑定与邮箱补全均使用原生表单；线上提供方回调需真实账号验收。

客户端兼容目前网站的 HttpOnly Cookie 会话，原生 HTTP 客户端持有 Cookie；写请求按当前服务契约发送 `Origin` 和 `X-Requested-With`。不会修改原网站后端，也不会把登录 Cookie 发给模型/TTS 服务。会话到期需要重新登录，尚无 refresh-token 接口。

使用现有接口：

| 接口 | 用途 |
| --- | --- |
| `POST /api/auth/login`、`GET /api/auth/me`、`POST /api/auth/logout` | 账号会话 |
| `GET /api/room/chat?limit=100` | 拉取完整问答轮次 |
| `POST /api/room/chat/turn` | 用稳定 `turnId` 幂等保存一轮对话，按长期记忆开关传递 `memoryEnabled` |

先将完整轮次写入本地，再上传；失败轮次留在对应账号的待同步队列。启动、手动刷新、完成对话、返回前台及前台每 30 秒重试同步。演示/访客/站点/账号使用不同缓存范围，不自动导入访客历史。服务器是已同步历史的准源，其他设备的删除和修改会在下次同步反映。

已登录账号的长期记忆捕获由现有后端处理；发送前检索网站记忆并注入本轮模型上下文，游客使用本机记忆。支持记忆检索、新增、编辑、删除、向量同步，以及云端日记分页阅读、生成、删除、存档导入/导出和人设编辑。已接入站点 SSE 实时订阅；原生系统推送尚未接入。

文章支持搜索、分类、排序、分页、HTML / Markdown 阅读、评论、点赞、收藏与前台有效阅读计数。广场支持留言、回复、点赞、检索及筛选；成长支持签到、任务、等级路径、邀请分享和记录；个人中心支持简介编辑、文章、留言、收藏、通知。

GET 数据按站点和账号缓存；弱网显示上次内容并提供重试。401 不会丢弃本机账号范围、草稿和待同步轮次，重新登录同一账号后继续同步。留言、回复等非幂等写操作不自动重复提交。

API Key 与会话 Cookie 使用系统安全存储；设置和会话缓存使用本地 preferences。macOS 直接分发版使用系统登录 Keychain，兼容 ad-hoc 签名。密码只用于当前登录请求，不持久化。

## 检查与构建

```sh
dart format --output=none --set-exit-if-changed lib test packages/tsukuyomi_live2d/lib packages/tsukuyomi_live2d/hook
flutter analyze
flutter test

# 本机准备好 SDK 和模型后，执行真实 Cubism 测试并输出渲染图
flutter test test/live2d_native_test.dart --dart-define=RUN_CUBISM_TESTS=true

# 检查实际原生图形后端：透明度像素校验和眨眼连续帧
flutter run -d macos -t tool/verify_live2d_rendering.dart

flutter build macos --debug
flutter build web
```

真实模型测试产物：`artifacts/native-live2d.png`。普通 CI 验证不带模型的开发壳；Release CI 从官方 SDK 与固定版本的原网站仓库取得资源并校验 SHA-256，运行真实模型测试，缺少 Cubism Core 时禁止发布。

五个平台的安装包由发布流水线统一构建，通过原生模型检查和包结构校验后发布至 [GitHub Releases](https://github.com/redchenk/tsukuyomi-space-app/releases)。自动化测试、真实后端联调及界面检查见 [整站验收记录](docs/native-full-site-implementation-2026-09-30.md)。外部服务、QQ 实号回调与已签名 iPhone 安装仍需对应账号和设备验证。

眨眼后高光发白的修正与原生验证方法见 [docs/live2d-blink-fix.md](docs/live2d-blink-fix.md)。

## 鸿蒙适配

HarmonyOS / OpenHarmony 适配维护在官方 [`ohos` 分支](https://github.com/redchenk/tsukuyomi-space-app/tree/ohos)，同步主线功能。[GitHub Releases](https://github.com/redchenk/tsukuyomi-space-app/releases) 提供 `ohos-arm64-unsigned.hap`，适用于 HarmonyOS 6.0.2 / API 22 及以上 ARM64 设备，须自行签名后安装。感谢 [HelloZeroNick](https://github.com/HelloZeroNick) 贡献移植；下载、签名与验收限制见 [鸿蒙适配说明](docs/harmonyos.md)。

## 贡献者

感谢参与月读空间开发与平台适配的贡献者。

| 作者 | 贡献 | 原始仓库与提交 |
| :--- | :--- | :--- |
| <a href="https://github.com/HelloZeroNick"><img src="https://avatars.githubusercontent.com/u/253844495?s=96&v=4" width="48" height="48" alt="HelloZeroNick 的头像" /><br />HelloZeroNick</a> | HarmonyOS / OpenHarmony 移植、平台工程、插件适配与首次 HAP 构建 | [原 fork 的 ohos 分支](https://github.com/HelloZeroNick/tsukuyomi-space-app/tree/ohos) · [原始移植提交](https://github.com/redchenk/tsukuyomi-space-app/commit/83f8a25fd4833986bca4105ef1e3930923a6d196) |

完整贡献记录见 [GitHub Contributors](https://github.com/redchenk/tsukuyomi-space-app/graphs/contributors)。鸿蒙移植的原始作者信息与提交历史保留在 `main`，`ohos` 继续作为专用构建与同步分支。

## 结构

```text
lib/core/                  HTTP、SSE、音频、凭据与缓存
lib/features/room/         Room 状态与响应式界面
lib/features/settings/     模型、TTS 与账号设置
lib/features/site/         原生登录与网站核心页面
lib/live2d/                角色场景和应用生命周期
packages/tsukuyomi_live2d/  Native build hook、C++ ABI、Dart FFI、Flutter renderer
test/                      传输、状态、布局与真实模型测试
tool/                      本地模型/SDK 准备工具
```

## 官方参考

- [Flutter 文档](https://docs.flutter.dev/)
- [应用架构建议](https://docs.flutter.dev/app-architecture/recommendations)
- [通过 FFI 绑定原生代码](https://docs.flutter.dev/platform-integration/bind-native-code)
- [响应式布局](https://docs.flutter.dev/ui/adaptive-responsive)
- [网络请求](https://docs.flutter.dev/cookbook/networking/fetch-data)
- [Cubism SDK](https://www.live2d.com/en/sdk/about/)

角色、背景和示例插画来自现有 tsukuyomi-space 项目，相关素材权利不因本仓库而改变。Cubism SDK 遵循 Live2D 自身许可，未随源码提交。
