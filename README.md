# 月读空间 · Flutter 原生客户端

Tsukuyomi Space 的独立 Flutter 客户端。0.5.0 整站测试版提供原生 Room、统一认证、内容阅读与创作、社区、游戏和管理页面，直接连接原网站 API。

整站原生页面包含入口、Hub、Wiki、图库、附件库、编辑器、像素工坊、辉夜跑酷、友链、公开主页、管理后台和 Live2D 工作台，支持跨设备事件、中文／日语／英语、全站搜索及八千代导览。后台只向有效登录的 admin／super_admin 显示和开放；本地、合并与云端记忆来源跟进原站最新逻辑。实现与验收边界见 [整站迁移记录](docs/native-full-site-implementation-2026-09-30.md)。

下载安装包见 [GitHub Releases](https://github.com/redchenk/tsukuyomi-space-app/releases)，配置与安装说明见 [release-guide.md](docs/release-guide.md)。发布包包括 Android APK、macOS Universal DMG、Windows 安装程序、Linux DEB 和供用户自签的 iOS IPA。

默认进入明确标记的离线演示模式。演示回复来自本地固定文本，不会请求 AI 或上传会话。连接真实服务需在「房间设置」填写模型地址并关闭演示模式。

## 与网站一致的双端界面

Room 按 [现有网站](https://yachiyo.hk/room) 的桌面和手机版分别实现，复用夜景、背景与角色素材：

- **桌面（宽度 > 860）**：顶部导航、左侧角色舞台、右侧聊天工作区，包含聊天／日记／资料／便签标签、快捷话题和输入框。
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

加载成功后「角色状态」显示 `Cubism Native`，支持注视、眨眼、呼吸、模型物理、表情和口型。信息按钮显示网格数量及最近一次模型更新耗时；该耗时**不代表 GPU 绘制时间或实际帧率**。模型更新跟随屏幕刷新，切到后台暂停；纹理着色器缓存复用，遮罩按网格边界裁剪。当前 Mac Release 基准的动画更新约 21fps → 60fps，数值不代表所有设备。

当前实现采用 **Cubism Native Core + Native Framework 物理计算，Flutter Canvas 绘制纹理三角网格**。没有 WebView、JavaScript 引擎或假角色动画。它用于验证模型与 Flutter 的原生数据链路；不是 Cubism 官方 GPU renderer 的直接封装。

已支持普通/反向遮罩、标准加法/乘法混合、multiply/screen 色彩；明确拒绝 Cubism 5.3 的离屏部件和扩展混合。网站表情与动作预设通过原生参数和舞台变换执行，支持队列、动作过渡、回复情绪反应与设置页 JSON 调试。任意 Cubism motion3 动作文件播放仍未实现。

## 连接模型与语音

点击设置，关闭「离线演示」，填写：

- **模型 API 地址 / Base URL**：例如本机 `http://localhost:11434/v1/chat/completions`，或你的服务商提供的 HTTPS 地址。
- **模型名称**：填写该端点实际提供的模型 ID。
- **API Key**：只在服务需要时填写，不使用 GitHub 令牌。
- **语音回复**：可选。选择服务预设，填写对应地址、模型、音色和独立密钥，先试听再保存。

聊天支持 OpenAI 兼容 Chat Completions / Responses、Anthropic Messages、Ollama 和网站代理，处理 **SSE、NDJSON 和完整 JSON**。UTF-8 分片、CRLF、结束标记、超时、取消和截断均有测试。设置中的 MCP 可列出工具，并按白名单在发送前调用搜索与图片理解，将结果加入模型上下文。未完成回复不写入历史，保留用户输入供重试。桌面 Enter 发送、Shift + Enter 换行，也支持 ⌘ Enter / Ctrl Enter；⌘ K / Ctrl K 打开本机历史搜索。移动端回车换行，点击按钮发送。

TTS 支持 OpenAI 兼容、MiMo、MiniMax、ElevenLabs、GPT-SoVITS 和网站代理，设置中可独立试听与停止。WAV/MP3 解码后分析真实 PCM 的 20ms RMS 音量包络，并与播放器时间对齐控制口型；仅解码不可用时采用降级包络。真实供应商音色与音素级口型仍需验收。语音失败不撤销已保存的文字对话。

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

已登录账号的长期记忆捕获由现有后端处理；发送前检索网站记忆并注入本轮模型上下文，游客使用本机记忆。支持记忆检索、新增、编辑、删除、向量同步，以及云端日记分页阅读、生成、删除、存档导入/导出和人设编辑。站点 SSE 实时订阅与系统推送尚未接入。

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
