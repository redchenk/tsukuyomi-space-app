0.6.3+9 / v0.6.3-beta.1，修复长 SVG 生成失败，应用图标统一使用原站月读空间图标。

- **自动模式长回复**：区分实际文字／工具参数与重复的 SSE 协议开销，修复不足 2MB 的作品被原始流量限制打断。正文 8MiB、传输 64MiB、JSON 16MiB 分别有界；原生只读取最近四条消息核对最终结果。
- **结构化 SVG**：支持的接口启用 JSON 输出模式，明确 SVG/XML 字符串转义和保存工具；一次修复会附具体校验错误及有界的出错内容。截断或空 JSON 也可修复一次；完整动作仍严格校验后才执行。401/429/5xx 不因格式约束重复请求，明确拒绝 JSON 模式的接口按提示词兼容并记住选择。
- **作品文件**：文件读写从 64KiB 调整到 1MiB UTF-8；超限写入保留原文件。生成动作与文件内容分离记录，避免把完整 SVG 重复塞进下一步提示。官方 DeepSeek 地址的输出预算为 32K tokens。
- **应用图标**：Android、iOS、macOS、Windows、Web 使用原站角色图标；Windows 安装器与 Linux 窗口、DEB、便携包入口一并处理，iOS 图标无透明通道，Web 提供安全区域图标。

本地完整回归 **517 项通过、无跳过**，静态分析无问题；发布与打包校验 40 项通过。本轮包含约 180KB 鹈鹕骑自行车 SVG 的真实 OpenCode 写入、超过旧 2MB 原始流量的分片回复、四协议结构化流程、转义／截断／空动作修复，以及越界写入和错误状态不重试。未接入用户 DeepSeek 在线账号。具体用例与限制见 [0.6.3 验证记录](https://github.com/redchenk/tsukuyomi-space-app/blob/v0.6.3-beta.1/docs/native-svg-icons-v0.6.3.md)。

保留 0.6.2 的公开阶段说明、32ms 合并的实时正文、工具状态与耗时、取消、无有效输出时的安全兼容切换和模式记忆；原生 Responses／Anthropic／Ollama 桥接仍按完整回复返回，结构化模式支持四协议流式聊天。[0.6.2 验证](https://github.com/redchenk/tsukuyomi-space-app/blob/v0.6.2-beta.1/docs/native-agent-progress-v0.6.2.md)。

延续 0.6.1 的文章分栏预览、180ms 合并刷新和滚动正文隔离；此前文章滚动受控场景的三次性能数据见 [0.6.1 验证记录](https://github.com/redchenk/tsukuyomi-space-app/blob/v0.6.1-beta.1/docs/native-fixes-v0.6.1.md)。

保留 0.6 整站功能：文章、创作、图库、附件、Wiki、像素工坊、游戏、管理和 Live2D 工作台均在 Flutter 内运行，连接原站相同业务接口。

- **整站入口与内容**：Hub、搜索、中文／日语／英语、主题、音乐、八千代使用导览；文章阅读与评论、发布和修改、素材分片上传与断点恢复、图库、完整 Wiki、友链及公开主页。
- **创作与游戏**：原生像素画布、导入导出及社区作品；使用原站项目和素材的辉夜跑酷，包含飞行、节奏、战斗、音效、触控、成绩与排行榜；独立 Live2D 导演工作台。
- **Room 与账号**：统一登录、注册、验证码、重设密码、QQ 授权和绑定表单；图片聊天、公开分享、云历史、日记、人设、知识、MCP 和真实 WAV／MP3 PCM 口型。支持本地、合并与云端记忆来源、重要性及置信度编辑。
- **最新原站契约**：独立可编辑昵称，登录用户名和 ID 固定，作者/公开主页/图库/留言/排行榜同步显示昵称；本机与远程 GPT-SoVITS 按地址自动选择直连或网站代理。
- **权限与恢复**：后台只向有效登录的 `admin`／`super_admin` 显示并开放；账号及站点隔离、跨设备事件、通知、每日访问去重、离线草稿和同步重试。

延续上一版 issues #1–#5 修复，并加入定向回归测试：旧服务请求不能携带新服务 Cookie；保存普通设置保留新会话分界；旧生成任务不能释放下一轮提交状态；离开文章后的迟到点赞／收藏响应作废；全屏角色同步加载、暂停和继续状态。

- **原生 Agent**：四种模型协议、严格结构化兼容、工作目录、工具进度、文件差异、审批、取消、无重放恢复；文章草稿版本检查、撤销和确认发布，上传使用已预览快照。
- **UI 与性能**：全站四组菜单、宽屏浮层/窄屏底部弹层、键盘与焦点、紧凑编辑器及固定工具栏；2,000 条消息场景 UI P95 约 91ms → 10.3ms，Raster P95 约 8.1ms → 6.0ms（M5/16GB，三次 Profile，详见验收记录）。

| 平台 | 下载文件后缀 |
| --- | --- |
| Android 常见手机 | `android-arm64-v8a.apk` |
| Android x86_64 模拟器 | `android-x86_64.apk` |
| iPhone／iPad 自签 | `ios-arm64-unsigned.ipa` |
| macOS Apple Silicon／Intel | `macos-universal.dmg` |
| Windows 10／11 x64 | `windows-x64-setup.exe` 或 ZIP |
| Ubuntu 22.04 x64 | `linux-x64.deb` 或 tar.gz |

安装说明见 **INSTALL.md**，下载校验和见 **SHA256SUMS.txt**。Android 延续同一发行签名，可覆盖升级；macOS／Windows 暂无发行商签名，iOS 包需用户自行签名后安装。

打开即进入 Room，无 Access 动画；默认关闭演示。首次在聊天区连接自己的模型，已有配置直接可聊；旧演示历史独立保留。桌面 Agent 复用模型配置，捆绑 OpenCode 1.18.33 与 Codex 0.159.0，无需预装 CLI。

QQ 实号回调、外部模型／音色以及手机 GPU 与已签名 iPhone 体验仍需对应账号和设备验收。完整 Agent OS 仍是独立应用，本版提供原生 Room Agent。完整核对表、真实性能数据及限制见 `docs/native-room-agent-v0.6.md`。

Windows 命令使用严格 MXC/PSEC 沙箱。系统缺少 PSEC 时停止命令，不回退到宽松的目录读取权限；此时文件工具、MCP 和站内 Agent 仍可用。支持 PSEC 的 Windows 实机命令尚待验证。
