# 0.6.3 SVG 生成与应用图标修复

版本 `0.6.3+9 / v0.6.3-beta.1`，上一发行源码 `f00a63c51cd540dc95ae5a148f289a31a5eee32d`。原站测试基线不变。

## 回复与文件大小

旧原生桥接累加整条 SSE 的网络字节，2MiB 里包含每个分片重复的 id、model、choices、tool_calls 等字段，导致作品实际正文很小也被中断。现在限制原生 SSE 正文／推理／工具参数合计 8MiB、原始流量 64MiB；单个 JSON 响应及请求限制为 16MiB，保留单事件与超时保护。原生核对最终结果读取最近四条消息，避免把旧 SVG 反复载入。

文件工具旧限制 64KiB 会拒绝较大的 SVG；现在读写允许 1MiB UTF-8，写入前校验字节数，超限保留原文件，仍使用原子替换、真实路径及符号链接检查。结构化动作最多 2MiB 字符，普通聊天原有长度限制保持原值。官方 `api.deepseek.com` 地址使用 32K tokens 输出预算，不对其他服务强制扩大模型预算。

## 结构化动作

兼容模式此前仅在系统提示里要求 JSON，修复时又没有携带上次回复与具体错误。现在在支持的 Chat Completions／Responses／Ollama 接口启用 JSON 输出格式，Anthropic 保留提示词和严格校验；明确拒绝格式参数时去掉该约束并记住当前地址和模型的兼容选择。401/429/5xx 不做格式兼容重提，最多两次参数协商分别处理 JSON／stream 的明确不支持。

系统提示给出正确转义 SVG/XML 字符串的完整动作示例，要求保存作品并简洁报告。一次格式修复包含具体错误、JSON 编码且有界的出错内容，并要求重新生成完整动作。截断、空输出同样可修复一次；禁止拼接未完成动作来执行。支持完整包裹的 JSON 代码块（包括 CRLF、大小写），仍拒绝多个对象或尾随可执行文字，动作及工具参数继续逐项严格校验。

已执行的写入在下一步提示中以路径与写入字节数记录，实际差异仍保留给用户查看；避免把整份 SVG 再作为待执行动作传回模型。模型说明与最终正文继续流式显示，操作只在完整验证后执行。

协议依据：[DeepSeek JSON Output](https://api-docs.deepseek.com/guides/json_mode/)、[Chat Completions 格式与输出预算](https://api-docs.deepseek.com/api/create-chat-completion/)、[Responses JSON 格式](https://api-docs.deepseek.com/api/create-response/)。这些协议测试不代替用户 DeepSeek 账号的在线实测。

## 月读空间图标

源图直接使用原站 `assets/icons/icon-512.png`，存于本项目 `assets/branding/app-icon.png`，保留原作者权利说明；不重新设计角色图。`tool/generate_app_icons.py` 只生成平台要求的尺寸与格式：

- Android 五种密度、iOS 完整 AppIcon 尺寸（RGB 无透明通道）、macOS 16–1024px、Windows 七种 ICO 尺寸及安装器图标。
- Linux 窗口从安装包 data 加载原站 PNG，DEB 使用同源 256px 图标；桌面入口文件名与既有 GApplication ID 一致，便携包也携带图标。
- Web favicon、普通图标和 maskable 安全区域图标，清理 PWA 默认 Flutter 标题与说明。

512px 原图的 1024px 平台素材为插值放大；应用标识与账号存储路径保持不变。

## 验证

新增 14 项定向用例涵盖：四协议结构化 SVG、空输出、XML 引号／换行修复、截断修复、JSON 不支持后的协商记忆、401/429/500 不重试、完整代码块与多个动作拒绝、UTF-8 超限不改文件、超过旧 2MiB 网络流量的回复。

真实 OpenCode 1.18.33 用约 180KB 的鹈鹕骑自行车 SVG 验证分片参数、写入一次、推理状态续轮与公开结果；完整生成文件与预期字节一致。本地完整回归 **517 项通过、无跳过**，静态分析无问题；发布工具 37 项与运行时打包 3 项通过。图标确认原站原图字节一致，27 个原生 PNG 与七档 Windows ICO 逐像素比对通过。三桌面安装包与五平台发行结果在发布前核验，最终结果记录在 Release。

```sh
flutter test test/agent_svg_test.dart
flutter test test/desktop_agent_test.dart test/deepseek_agent_runtime_test.dart test/agent_svg_test.dart --dart-define=RUN_AGENT_TESTS=true --dart-define=AGENT_BUNDLE_PATH=build/macos/Build/Products/Release/tsukuyomi_space_app.app/Contents/Resources/agent
python tool/generate_app_icons.py
```

发行签名、iOS 自签、外部账号、Windows PSEC 和手机 GPU 的限制与之前的验收记录相同。
