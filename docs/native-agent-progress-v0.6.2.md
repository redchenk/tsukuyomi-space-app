# 0.6.2 DeepSeek、流式输出与任务进度

版本 `0.6.2+8 / v0.6.2-beta.1`。上一发行源码 `072275bd739e23b573e254e9d39d4e9183a48773`，原站测试基线 `6f784dd80093ab43c7d1140485411a77e82df366`。

## 问题与修复

原生模型桥接此前请求 `stream: false`，收到完整回复后才发出 SSE；中文 SSE 缺少 UTF-8 声明，Dart 默认 Latin1 编码导致中文输出报错。Chat Completions 现在直接转发真实 SSE、及时 flush，并显式使用 UTF-8。分片工具参数保留到协议完成再由运行时调用网关，不把未完成参数当作操作执行。

OpenCode 模型配置明确使用用户的模型 ID；DeepSeek 配置 `interleaved.field: reasoning_content`，让工具调用续轮保留供应商要求的状态。[DeepSeek 官方说明](https://api-docs.deepseek.com/guides/thinking_mode/)要求在工具续轮回传这些字段。界面不显示这些推理内容，只显示简洁公开说明和阶段状态。

自动模式从提交开始显示任务和阶段计时。30 秒内无有效模型输出且没有工具执行时，取消原生请求，再尝试结构化模式；角色占位和 SSE 保活不算有效输出。400/422 的工具不兼容错误同样可以切换一次。401、429、5xx 保留原错误，不提交第二种模式；已有工具执行时不重放任务。成功的兼容选择按账号、站点及模型配置记忆，新会话不再重复等待同一失败路径。

结构化模式只增量显示顶层 `commentary` 和最终 `text`；完整 JSON 和工具参数通过严格验证后才执行。无效动作最多修复一次，预览作废，取消不会执行半个动作。恢复时排除中断的预览，继续沿用账号隔离、审批和操作不重放约束。

## 用户看到的过程

复杂任务显示短计划、重要阶段更新和实际结果；简单任务保持简洁。工具开始、结束合并到同一行，显示文件路径或命令、运行／完成／失败／拒绝状态。原始工具 JSON 默认收起；公开回复用 Markdown 渲染。自动跟随新内容，用户查看历史时保持位置，提供回到最新进度的入口。界面流式更新合并到每 32ms 至多一次。

错误只显示一次；取消和关闭会停止进程请求与刷新定时器。原生自动模式缺少首个有效输出的保护之外，模型桥接总响应上限为 180 秒，读取空闲超时为 45 秒。

## 验证

新增 `agent_progress_test.dart`：中文／转义／代理对增量解析、最终答案在请求完成前可见、工具说明流式显示且取消不执行、真实 HTTP 中文 SSE 转发。界面覆盖 360、390、768、1280、1920 五种宽度 × 中文／日语／英语，含深浅主题与 1.6 倍字体，检查无溢出、隐藏原始工具内容和实时进度。

新增 `deepseek_agent_runtime_test.dart` 使用发行包固定 OpenCode 1.18.33 的真实进程：

1. DeepSeek 形状的中文 SSE、推理字段与分片工具调用；先显示公开说明，再写文件一次，再返回 Markdown，总共两次模型请求。第二次请求要求回传完整 `reasoning_content`，缺少即拒绝。
2. 原生仅返回角色占位／保活时取消请求，切换结构化并完成文件任务；下一新会话直接使用已验证的结构化模式。
3. 原生收到 HTTP 429 时取消运行时重试、显示限流错误，禁止结构化重提任务，文件未修改。

以上是本地协议 fixture 验证，没有用户 DeepSeek 密钥，不能代替供应商账号的在线实测。Chat Completions 原生桥接真实流式；原生 Responses／Anthropic／Ollama 桥接仍按完整回复返回，结构化模式使用既有四协议流式聊天。

本地完整回归 **503 项通过、无跳过**（原站临时后端、原生 Cubism、捆绑运行时均启用）；新增 22 项、原生 Agent 定向回归 36 项通过。静态分析无问题；发布工具 37 项与运行时打包 3 项通过。平台构建和发行资产结果在 Release 发布前核验并记录。运行时仍固定 OpenCode 1.18.33 与 Codex 0.159.0，许可及校验文件随安装包提供。Windows PSEC、第三方账号、手机 GPU、发行签名等限制与 [0.6 验收](native-room-agent-v0.6.md) 相同。

```sh
flutter test test/agent_progress_test.dart
flutter test test/desktop_agent_test.dart test/deepseek_agent_runtime_test.dart --dart-define=RUN_AGENT_TESTS=true --dart-define=AGENT_BUNDLE_PATH=build/macos/Build/Products/Release/tsukuyomi_space_app.app/Contents/Resources/agent
```
