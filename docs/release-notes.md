Flutter 原生核心应用验证版，直接连接原网站账号与数据，保留 OpenAI 兼容 LLM / TTS 配置与真实调用。

- **Live2D**：修复 Android 原生库遗漏系统链接库导致模型无法加载。Android 与 iOS 模拟器均验证 409 网格、2 纹理及动画。桌面按 vsync 更新，缓存纹理并缩小遮罩离屏区域；本机 Mac Release 动画基准约 21fps → 60fps，眨眼透明度像素回归通过。
- **原生核心页面**：密码及验证码登录、注册与重设密码，Room、会话与记忆、文章阅读、广场、成长、个人中心和通知。桌面文章横排、手机纵排，复用网站场景与内容素材。
- **网站同步与恢复**：真实网站 API；账号隔离缓存、草稿恢复、401 重新登录后补传、稳定 turnId 去重、前台同步重试。记忆检索进入 LLM 上下文；留言不盲目自动重发。
- **iOS**：新增未签名 iPhoneOS arm64 IPA，供用户自签，不包含证书或描述文件。

| 平台 | 下载文件 |
| --- | --- |
| Android 常见手机 | `android-arm64-v8a.apk` |
| Android x86_64 模拟器 | `android-x86_64.apk` |
| iPhone / iPad 自签 | `ios-arm64-unsigned.ipa` |
| macOS Apple Silicon + Intel | `macos-universal.dmg` |
| Windows 10/11 x64 | `windows-x64-setup.exe` 或 ZIP |
| Ubuntu 22.04+ x64 | `linux-x64.deb` 或 tar.gz |

首次使用：设置 → 关闭离线演示 → 分别填写模型和语音的接口、模型、Key → 测试连接与试听 → 保存。网站登录与模型服务是独立配置，安装包不含共享 Key。

安装说明见 **INSTALL.md**，校验和见 **SHA256SUMS.txt**。macOS / Windows 暂无发行商签名；Android 使用持久发行密钥。iOS 需签名后才能安装，尚未做已签名真机验收。

本版支持上述核心链路；QQ OAuth、头像上传、投稿编辑器、百科、图库、游戏、系统推送等仍使用网站或留待后续。外部付费 LLM/TTS 音色和各手机 GPU 表现仍需要使用实际账号与设备验证。
