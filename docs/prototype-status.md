# 技术样机验证记录

日期：2026-09-27。范围：独立 Flutter Room 客户端，复用现有网站账号与会话接口。

## 已验证

开发环境为 macOS Apple Silicon、Flutter 3.47.5、Dart 3.13.4、Xcode 27.0、Cubism SDK for Native 5 R5。

| 检查 | 结果与边界 |
| --- | --- |
| Dart 格式、`flutter analyze` | 通过，无分析问题 |
| `flutter test --dart-define=RUN_CUBISM_TESTS=true` | 33 项通过，含真实模型和眨眼连续帧测试；1 项本机截图用例默认跳过，已单独开启运行通过 |
| macOS Debug 构建 | 通过，已启动原生窗口并完成本地演示对话 |
| Web 构建 | 通过；只提供界面与演示，不提供 Cubism Native 或站点登录 |
| Cubism 原生数据链路 | 加载已有八千代模型、参数驱动网格变形、运行物理、绘制完整角色并释放资源 |
| 布局 | 1440×960、1024×640、861×700 桌面与 844×390、390×844、320×640 移动布局通过 widget 测试，含横竖屏键盘避让 |
| 网站 UI 对照 | 1440×960 桌面和 390×844 手机截图人工对照；Mac 原生窗口已验证新会话与资料标签；见 `ui-alignment.md` |
| 新增交互 | 新会话保留历史并隔离模型上下文、本机便签独立保存、安静陪伴切换、搜索快捷键通过测试 |
| 眨眼后白闪 | 在 macOS 原生渲染中复现眼部高光过亮；分离透明度与颜色滤镜后复查 30 帧，普通／加法／带遮罩加法三个原生像素检查通过，见 `live2d-blink-fix.md` |
| SSE 传输 | UTF-8 跨字节分片、CRLF、明确结束、截断、服务错误与取消 |
| 本地保存与同步状态 | 使用测试替身验证离线队列、稳定 turnId 重试、账号隔离、取消保留输入、磁盘失败不上传、服务端删除反映 |
| 语音 | 16-bit PCM WAV 解析、RMS 包络与损坏输入拒绝；尚未真实供应商联调 |

真实模型测试会生成 `artifacts/native-live2d.png`，该图已经人工检查。它证明当前模型可以显示，不能替代官方 renderer 的逐像素一致性、复杂模型兼容性或设备性能测试。

macOS 工程的末尾构建脚本仅清除生成 `.app` 中阻碍 codesign 的 FinderInfo/ResourceFork；这是为 Desktop/iCloud 文件系统附加元数据的情况准备的，不修改源文件。调试版使用 ad-hoc 签名与登录 Keychain；正式签名、公证和商店发布未完成。

本机 Desktop 同步目录仍会异步附加元数据，因此将生成的 `build` 目录移到 `~/Library/Caches/tsukuyomi-prototype/flutter-build` 并建立本地符号链接。该链接被忽略，不提交，不改变其他机器的 Flutter 配置。

## 平台状态

| 平台 | 工程与 CI | 设备验证 |
| --- | --- | --- |
| macOS | 本机 Debug 构建通过；CI 配置已提供 | Apple Silicon 原生窗口已启动，真实 Live2D 已显示 |
| Android | 工程与 APK Debug CI 配置已提供 | 尚无 Android SDK/模拟器或真机验证 |
| iOS | 工程已提供 | 尚无模拟器运行、真机签名与测试 |
| Windows | 工程与 Debug CI 配置已提供 | 尚未在 Windows 构建或运行 |
| Linux | 工程与 Debug CI 配置已提供 | 尚未在 Linux 构建或运行 |
| Web | 本机构建通过，CI 配置已提供 | 无原生 Live2D；非主要交付平台 |

CI 不带 Cubism SDK 和角色模型，原生构建使用明确标记不可用的占位库。CI 的通过不能算作 Cubism 在该平台的验收。Windows、Android、iOS 的 SDK 链接路径已经配置，仍需各自环境实测。

## 当前实现取舍

- Core 和 Framework 负责模型计算、变形和物理；Dart FFI 读取网格；Flutter Canvas 绘制三角形、遮罩、颜色与常见混合。没有 WebView。
- 模型及绘制目前运行在 UI isolate，更新上限 30 Hz。界面显示的模型更新时间不包含完整 raster/GPU 时间。
- 模型 SDK 和原始 Live2D 资源仅在本机复制，未纳入 Git。首次克隆需要按 README 准备资源，否则清楚显示 PREVIEW。
- 演示使用固定本地回复。真实模式使用用户配置的 Chat Completions SSE，TTS 使用独立 Speech WAV 端点。
- API Key 与会话 Cookie 进入系统安全存储；登录密码不保存。站点 Cookie 不会传给模型或 TTS。
- 已同步会话以服务端为准；待上传轮次先落本地。此版本不合并访客与账号历史，不订阅站点实时 SSE。
- 桌面沿用网站双栏工作区，移动端沿用全屏场景叠加聊天；日记、音乐和其他站点导航仍通过浏览器打开网站，尚未原生迁移。便签只在本机保存。
- 快捷发送通过 widget 测试；macOS UI 自动化尚未成功触发组合快捷键，需用物理键盘复核。原生窗口已经验证按钮发送；中文输入法组合文本仍需单独验收。

## 下一阶段

1. 使用专门测试账号与模型/TTS 凭据，完成真实登录、会话同步、到期重新登录、音频播放与口型联调。没有用生产账号写入测试对话。
2. 在 Android 和 iOS 真机验证原生库 ABI、启动、键盘、安全存储、前后台音频与网络限制，然后覆盖 Windows/Linux。
3. 用 Flutter DevTools 测量帧时间、内存、长时间运行和耗电。必要时迁移到官方 GPU renderer/原生纹理，而不是依据单次模型更新时间做性能结论。
4. 补齐动作文件播放、表情过渡、行为调度，以及现有网站的记忆检索注入、日记、图片与 OAuth 等产品能力。
5. 改善离线启动的账号恢复：目前首次恢复 Cookie 必须成功调用 `me` 才能显示账号范围缓存，离线重启时会暂时进入访客范围。
6. 完成发布签名、应用图标、素材许可核对及商店流程。当前样机不能视为可发布正式版。
