Room / Room settings 功能对齐版，保留已有原生登录、文章、广场、成长、个人中心与网站数据连接。

- **Room**：真实流式对话、主动开场、停止/重试、最新一轮编辑与重新生成、按网站规则分句、图片压缩上传与历史回读、分享图片/公开链接/撤销。PC 双栏与手机覆盖式布局复用网站场景，移动端为原生 Cubism 动画。
- **日记、记忆与恢复**：结束会话生成日记、角色人设、阅读/导入/导出/合并/删除，网站同账号同步和版本冲突保护；失败保留录制与已生成日记。图片与会话离线保存，登录过期后补传；游客本地记忆检索、知识库即时编辑。
- **完整设置页**：8 分区、配置搜索、未保存提示、模型目录及连接测试、多种 TTS 试听、MCP 工具、Live2D 表情/动作队列调试、角色尺寸位置。房间音乐、环境定位、资料和便签均接入实际功能。
- **服务协议**：OpenAI 兼容 Chat / Responses、Anthropic、Ollama；TTS 支持 OpenAI 兼容、MiMo、MiniMax、ElevenLabs、GPT-SoVITS 和网站代理。安装包不含共享密钥。

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
