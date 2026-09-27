# 0.3.0 核心应用验证记录

2026-09-27，Flutter 3.47.5 / Dart 3.13.4。原网站仓库只读，所有应用改动在 tsukuyomi-space-app。

## 原生与性能

- Android：修复共享库缺少 libm / liblog 链接；增加链接期 `--no-undefined`。Release APK 在 Android API 35 x86_64 模拟器安装、启动并完成 120 次动画更新，输出 `TSUKUYOMI_LIVE2D_OK meshes=409 textures=2`。[运行记录](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/36319494599)。最终发布流水线会再检查当次提交。
- iOS：iOS 27 模拟器实际运行相同模型检查并输出成功标记。iPhoneOS Release `--no-codesign` 构建通过；IPA 打包检查 arm64、Payload 结构、全部必要 Framework 与模型资源。尚无自签后的物理 iPhone 验收。
- macOS：真实 Metal/Impeller 透明度像素结果与预期一致（normal、additive、masked additive）；自然眨眼 30 连续帧检查未见复发白闪。
- 相同 Mac、相同 409 网格角色、650×800 场景，各预热 2 秒、采样 8 秒：原 30 Hz 阈值在 vsync 抖动下约 20.99 次更新/秒；移除阈值后约 59.99 次/秒。优化后 raster P95 11.98ms。原始日志为本机 `/tmp/tsukuyomi-benchmark.log`；该结果不代表其他 GPU 或手机。
- Windows、Linux、macOS、Android 和 iOS 的 Release 构建由发行流水线完成，构建本身不替代各平台真机使用验收。

## 数据与恢复

- 67 项自动化测试通过，包含真实 Cubism 测试、LLM/TTS 协议、页面及恢复逻辑。`flutter analyze` 无问题。
- 原网站 `tests/e2e-server.cjs` 使用隔离临时数据库。`flutter test test/site_backend_integration_test.dart --dart-define=RUN_WEBSITE_INTEGRATION=true` 通过：登录与注销、旧 Cookie 撤销、会话稳定 ID 去重、记忆 CRUD、文章与阅读令牌、13 秒有效阅读回执、点赞、收藏、留言回复、简介、签到及分享去重。
- 断网完成一轮对话后重启，恢复原账号草稿与待同步轮次；401 后保留内容，重新登录原账号完成一次补传。缓存按 origin 和 account 隔离；迟到的原账号响应不会覆盖新账号 Cookie。
- 发送前使用网站记忆 `context`，登录过期后不会复用上轮记忆；登录 Cookie 不发送给 LLM。
- 非幂等社区写操作失败后保留草稿并提示手动重试。文章 GET 和辅助内容有离线缓存及明确重试入口。

## 界面与范围

原生桌面截图和 Flutter 移动渲染与网站同路由、同访客数据对比；另有 320 / 390 / 1280 宽度的核心页面及登录流程布局测试。细节见根目录 `design-qa.md`。移动渲染截图不能替代 iOS / Android 实机字体、键盘及 GPU 验收。

本文覆盖核心验证版。QQ OAuth、头像上传、投稿编辑器、百科/图库/游戏、网站完整行为调度、SSE 实时订阅、系统推送及图片聊天尚未原生实现。实际付费模型和 TTS 音色需用户使用自己的服务验证。
