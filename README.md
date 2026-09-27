# 月读空间 · Flutter 原生技术样机

Tsukuyomi Space 的独立 Flutter 客户端。当前聚焦 **Room：原生 Live2D → 流式对话 → WAV 语音与口型 → 本地保存和账号会话同步**。

默认进入明确标记的离线演示模式。演示回复来自本地固定文本，不会请求 AI 或上传会话。连接真实服务需在「房间设置」填写模型地址并关闭演示模式。

## 环境与启动

本次开发使用 Flutter **3.47.5** / Dart **3.13.4**。平台项目包括 Android、iOS、macOS、Windows、Linux、Web。

```sh
flutter pub get
flutter run -d macos
```

首次克隆不包含 Cubism SDK 和角色模型，仍可运行界面和对话功能，角色区域会标记为 `PREVIEW`。Web 仅作为界面预览，不提供 Cubism Native 或站点账号登录。

macOS 调试通过 Swift Package Manager 集成插件。iOS 需要相应 Xcode SDK，Android 需要 Android SDK/NDK。Windows 和 Linux 在各自系统构建。

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

加载成功时显示 `LIVE2D NATIVE`，支持注视、眨眼、呼吸、模型物理、表情和口型。信息按钮显示网格数量及最近一次模型更新耗时；该耗时**不代表 GPU 绘制时间或实际帧率**。样机将模型更新限制为 30 Hz，切到后台暂停。

当前实现采用 **Cubism Native Core + Native Framework 物理计算，Flutter Canvas 绘制纹理三角网格**。没有 WebView、JavaScript 引擎或假角色动画。它用于验证模型与 Flutter 的原生数据链路；不是 Cubism 官方 GPU renderer 的直接封装。

已支持普通/反向遮罩、标准加法/乘法混合、multiply/screen 色彩。明确拒绝 Cubism 5.3 的离屏部件和扩展混合；还未迁移网站完整的行为调度器、动作文件播放与表情过渡。

## 连接模型与语音

点击设置，关闭「离线演示」，填写：

- **Chat Completions 完整地址**：例如本机 `http://localhost:11434/v1/chat/completions`，或你的服务商提供的 HTTPS 地址。
- **模型名称**：填写该端点实际提供的模型 ID。
- **API Key**：只在服务需要时填写，不使用 GitHub 令牌。
- **语音回复**：可选。填写兼容 Speech API 的完整地址、模型、音色和独立密钥。

聊天目前支持 Chat Completions **SSE**，不支持 Responses/Anthropic 专用协议或工具调用。UTF-8 分片、CRLF、结束标记、超时、取消和截断均有测试。未完成回复不写入历史，保留用户输入供重试。桌面可用 ⌘ Enter / Ctrl Enter 发送。

TTS 请求 `response_format: wav`，目前分析 16-bit PCM WAV 的 20ms RMS 音量包络，并与播放器时间对齐控制口型。支持停止播放；尚未验证真实供应商音色或音素级口型。语音失败不撤销已保存的文字对话。

远程服务要求 HTTPS；HTTP 仅用于 localhost/回环地址及 Android 模拟器主机 `10.0.2.2`。手机上的 localhost 指手机自身，不能直接访问电脑的 Ollama。原生应用的网络访问仍受各平台网络权限约束。

## 登录与同步

设置中的站点默认 `https://yachiyo.hk`。保存设置后，通过右上角登录现有账号；样机只实现用户名/邮箱 + 密码，未实现 QQ OAuth、注册或密码找回。

客户端兼容目前网站的 HttpOnly Cookie 会话，原生 HTTP 客户端持有 Cookie；写请求按当前服务契约发送 `Origin` 和 `X-Requested-With`。不会修改原网站后端，也不会把登录 Cookie 发给模型/TTS 服务。会话到期需要重新登录，尚无 refresh-token 接口。

使用现有接口：

| 接口 | 用途 |
| --- | --- |
| `POST /api/auth/login`、`GET /api/auth/me`、`POST /api/auth/logout` | 账号会话 |
| `GET /api/room/chat?limit=100` | 拉取完整问答轮次 |
| `POST /api/room/chat/turn` | 用稳定 `turnId` 幂等保存一轮对话，`memoryEnabled: true` |

先将完整轮次写入本地，再上传；失败轮次留在对应账号的待同步队列。启动、手动刷新、完成对话及返回前台时同步。演示/访客/站点/账号使用不同缓存范围，不自动导入访客历史。服务器是已同步历史的准源，其他设备的删除和修改会在下次同步反映。

长期记忆**捕获**由现有后端处理；样机尚未接入记忆检索注入、站点 SSE 实时订阅、站内推送、图片聊天或日记。

API Key 与会话 Cookie 使用系统安全存储；设置和会话缓存使用本地 preferences。macOS Debug 使用系统登录 Keychain，以支持本机 ad-hoc 调试签名；Release 使用 Data Protection Keychain，并需要开发者签名与 Keychain capability。密码只用于当前登录请求，不持久化。

## 检查与构建

```sh
dart format --output=none --set-exit-if-changed lib test packages/tsukuyomi_live2d/lib packages/tsukuyomi_live2d/hook
flutter analyze
flutter test

# 本机准备好 SDK 和模型后，执行真实 Cubism 测试并输出渲染图
flutter test test/live2d_native_test.dart --dart-define=RUN_CUBISM_TESTS=true

flutter build macos --debug
flutter build web
```

真实模型测试产物：`artifacts/native-live2d.png`。普通 CI 使用明确返回不可用状态的原生占位库，不下载或分发私有模型/SDK，不将占位库测试作为 Live2D 验证。

当前验证记录与未完成项见 [docs/prototype-status.md](docs/prototype-status.md)。CI 构建成功仅证明相应工程能够打包，不代表真机验收或应用商店发布完成。

## 结构

```text
lib/core/                  HTTP、SSE、音频、凭据与缓存
lib/features/room/         Room 状态与响应式界面
lib/features/settings/     模型、TTS 与账号设置
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
