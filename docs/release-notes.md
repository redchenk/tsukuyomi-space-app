可安装的 Flutter 原生房间验证版，沿用网站的桌面/移动端布局，内置月见八千代 Live2D，保留眨眼白闪修复。

- 支持直接调用 OpenAI 兼容 LLM：自定义 Base URL、模型、Key，流式回复与 JSON 返回，独立连接测试。
- 支持 OpenAI 兼容 TTS：独立地址、模型、音色、Key，WAV / MP3、试听、自动朗读与停止/重播；16-bit PCM WAV 支持口型。
- Key 使用系统安全存储，重启保留配置。没有内置共享 API Key，需要填写你自己的服务。

| 平台 | 下载文件 |
| --- | --- |
| Android 常见手机 | `android-arm64-v8a.apk` |
| Android x86_64 模拟器 | `android-x86_64.apk` |
| macOS Apple Silicon + Intel | `macos-universal.dmg` |
| Windows 10/11 x64 | `windows-x64-setup.exe` 或便携 ZIP |
| Ubuntu 22.04+ x64 | `linux-x64.deb` 或 tar.gz |

安装后：设置 → 关闭离线演示 → 配置模型并测试连接 → 开启语音、配置 TTS 并试听 → 保存。模型和语音 Key 需要分别填写。

macOS 暂无 Developer ID 签名/公证，Windows 暂无代码签名，首次启动可能出现系统来源提示；Android APK 使用持久发行密钥签名。iOS 按当前计划暂不发布；当前 Cubism SDK 不支持 32 位 ARM，因此不发布旧 32 位 Android 包。

完整安装说明和验证步骤见附件 **INSTALL.md**；校验和见 **SHA256SUMS.txt**。本版仍是验证版：CI 验证真实原生模型、协议和各平台 Release 构建；外部付费服务及各设备音频表现由实际账号和设备验收。
