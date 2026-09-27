# 月读空间 0.2.0 测试版

## 安装

- Android：安装 `android-arm64-v8a.apk`（绝大多数手机）。x86_64 模拟器选择 x86_64。当前 Cubism SDK 已不提供 32 位 ARM 库，因此不发布 32 位 APK。允许安装来自浏览器或文件管理器的应用。所有 APK 使用同一持久发行密钥签名，可覆盖升级本测试版。
- macOS：打开 DMG，将应用拖到 Applications。Universal 包同时支持 Apple Silicon 和 Intel。当前没有 Developer ID 签名和公证；首次启动可能需在“系统设置 → 隐私与安全性”允许打开此应用。无需关闭系统安全功能。
- Windows 10/11 x64：运行 setup.exe。按当前用户安装，无需管理员权限；当前未使用商业代码签名，SmartScreen 可能显示未知发布者。便携 ZIP 解压完整目录后也可运行。
- Linux x64：Ubuntu 22.04 及更新版本，推荐 `sudo apt install ./tsukuyomi-space-0.2.0-linux-x64.deb` 自动安装音频依赖。需桌面登录会话及 Secret Service（如已解锁的 GNOME Keyring）保存密钥。tar.gz 为便携包，依赖见仓库打包脚本。
- iOS：本次不发布，等待 Apple 开发者签名和描述文件。

## 配置真实模型和语音

1. 打开房间右上角“设置”，关闭“离线演示”。
2. 模型 API 地址填服务商 Base URL（如 `https://api.example.com/v1`）或完整 `/v1/chat/completions` 地址；填模型 ID 和 API Key。
3. 点击“测试模型连接”。收到真实接口回复后保存。测试不会写入聊天历史。
4. 开启“语音回复”，单独填写 TTS 服务地址、模型 ID、音色 ID 和 Key。即使共用服务商，也需要在语音栏填写 Key。
5. 点击“语音试听”；WAV 支持 16-bit PCM 音量口型。如果服务只支持 MP3，选择 MP3（与原网站一致，MP3 目前不驱动口型）。保存后新回复会自动朗读，可停止或重播。

根域名自动补 `/v1/chat/completions` 或 `/v1/audio/speech`；带版本的 Base URL 在末尾补对应路径。自定义网关请填写完整路径。此版支持 OpenAI 兼容协议，不包含网站的全部供应商专有协议（如 MiMo、ElevenLabs、Minimax）。LLM 支持 SSE 流式返回以及 JSON 完整返回。

请求直接从设备发送到所填写的服务商，消耗你自己的服务额度；安装包不含共享 Key。API Key 保存在系统安全存储，对话缓存保存在本机。启用网站账号同步后，对话按现有房间逻辑同步到对应站点。

远程接口需 HTTPS。本机 HTTP 支持 localhost、127.0.0.1、::1；Android 模拟器可用 10.0.2.2 连接宿主机。手机 localhost 指向手机本身；连接电脑上的服务请提供 HTTPS 地址。

## 建议验证

- 重启后设置和 Key 是否保留。
- 连续多轮中文对话、停止生成、再发消息是否正常。
- 语音试听、自动朗读、停止/重播是否正常。
- Live2D 眨眼白闪修复是否仍然正常，WAV 语音口型是否同步。
- 移动端键盘弹出、桌面调整窗口、登录同步及离线重新打开。

发布检查包括自动化协议测试、原生模型加载、各平台 Release 编译和安装包结构检查。外部付费 LLM/TTS 的账号、模型权限及设备声卡环境，需使用你的实际服务和设备验收；本次没有内置或借用生产凭据。

## 开发者复现原生服务验收

终端 1 启动 `python3 tool/release/smoke_server.py`；终端 2 执行 `flutter run -d macos --release -t tool/verify_native_services.dart`。此检查只使用回环接口和独立临时测试键，验证 Release 安全存储、HTTP 中文 SSE、WAV 播放完成及口型包络。服务端返回测试文本与短音调，不代表外部模型质量测试。完成后重新用 `lib/main.dart` 构建正式房间。
