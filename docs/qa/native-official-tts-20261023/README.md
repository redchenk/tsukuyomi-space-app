# 官方 TTS 与 v0.6.28-beta.1 发布验证

版本 `0.6.28+35`，标签源码为 `ee54e2498e87ed35f1c91f3b6253302f3e87df46`。[PR #11](https://github.com/redchenk/tsukuyomi-space-app/pull/11) 已合入 main，[公开 Release](https://github.com/redchenk/tsukuyomi-space-app/releases/tag/v0.6.28-beta.1) 提供 Windows、macOS、Linux、Android、iOS 和 HarmonyOS 安装文件。

- [标准发布流程](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39969831642)全部成功：静态分析通过，1,054 项 Flutter 测试通过、19 项跳过，40 项发布脚本测试和 3 项 Agent 脚本测试通过。Android 模拟器原生回归通过输入法、消息延迟加载、角色渲染、游戏接续与应用更新标记。
- [鸿蒙同源码构建](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39969824009)与[复用产物的补包流程](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39974965530)成功。HAP 的版本、构建号、源码与 Release 对应。
- GitHub 的 16 个公开附件均已实际下载，检查大小、SHA-256、两份校验清单、安装说明及第三方声明，见 [Release 验证](release-validation.json)。
- 对实际下载包检查 Android 的 Cubism 原生依赖，IPA/HAP 的版本与发布结构，Windows ZIP 的 CRC、运行时及 WebView2，Linux TAR/DEB，macOS DMG、双架构与签名完整性，见 [包检查](package-inspection.json)。桌面运行时清单及许可文件的哈希通过。

更新继续使用既有阿里云北京分发服务。App 与官网从 `https://downloads.yachiyo.hk/releases.json` 获取发布信息，文件从同域 `/releases/v0.6.28-beta.1/` 获取；受限接收端保持为 `tool/release/distribute.py` 中的原有地址，分发工作流和 App 更新器源码未改变。

[完整分发任务](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39976259972)已成功，日志确认接收 16 个已校验文件。鸿蒙补包后的首个自动分发被取消任务事件替换并跳过，因此在发布任务全部结束后手动运行了原有分发流程。北京站的 16 个文件均已实际下载，大小、SHA-256 与两份清单一致，见[北京站验证](mirror-validation.json)。

公开版本目录仅含本版，版本信息返回 `Cache-Control: no-store`，当前 APK 的 Range 下载返回 206，旧版 APK 返回 404。使用空的临时缓存执行 App 检查、下载及校验，成功取得本版 IPA，见[更新测试日志](app-update-network.txt)与[分发检查](distribution-checks.json)。官网六个平台的下载入口均已指向北京站本版文件，包含鸿蒙自签包，见[官网链接](website-download-links.json)。完整构建任务与源码记录见[来源检查](source-checks.json)。

官方 TTS 协议与界面测试使用模拟服务。未创建真实付费合成任务，未操作钱包付款、供应商配置或支付渠道开关，也未进行 Google Play 新版本提交。实际音色、真机播放、口型、性能和钱包扣费仍需真实设备与账号验收。iOS IPA 与 HarmonyOS HAP 未签名；macOS 使用临时签名校验，不代表 Developer ID 签名或公证。
