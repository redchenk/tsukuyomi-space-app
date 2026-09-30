# 辉夜快跑原项目素材

这份素材来自月读空间部署的实际游戏包，保留其 1 个舞台、69 个角色、114 种积木 opcode、原角色/场景/音效及关卡脚本。原作者入口由原站 GamePage 提供：

- 原作者：https://www.bilibili.com/video/BV1Bmgx6aEvJ/
- 游戏包：https://yachiyo.hk/game-runtime/kaguya-run-ef04c26b4900-%72%33.h%74%6dl
- 获取时间：2026-09-30
- 游戏 HTML SHA-256：`65e9088158219516cfb851ee196304d3a8e2aada4844e95870ab27b765539639`
- 解压来源：游戏包内 Base85 小端编码的 Scratch SB3 ZIP。
- 项目修补：同一发布包中的 `patchGameProject`，标记 `postgame-stage-cycle-v5`。原修补负责分数阶段、连续轮回和飞船控制提示。

`project.json` 保留原积木、变量、广播、克隆、造型及声音元数据，仅去掉编辑器中的坐标/注释。新增的 `file`、`imageWidth/Height`、`alphaBounds`、`maskOffset/Length`、`physicsHull` 是原素材生成的原生绘制/碰撞数据。

PNG/WAV 保留原始内容。8 个 SVG 造型使用 librsvg 转为原生 PNG，按 2 倍分辨率同步放大旋转中心；原 SVG 仍随包保留。`masks.bin` 保存每个造型 alpha 大于 0 的逐像素碰撞位图，`physicsHull` 保存同一透明轮廓的凸包。

Flutter 通过 `KaguyaRuntime` 原生执行这些脚本，通过 `CustomPainter` 显示造型，通过 audioplayers 播放原声音，通过纯 Dart Forge2D 执行原 griffpatch 物理扩展使用的 Box2D。运行时不加载 HTML、不执行 JavaScript，也不使用 WebView。

这些第三方游戏素材没有在原包中提供独立授权文本；本文件记录来源与加工方式，不改变原作者的权利。
