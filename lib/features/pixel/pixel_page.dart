import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/room_files.dart';
import '../../core/site_repository.dart';
import '../../core/site_client.dart';
import '../../core/site_localization.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import '../site/hub_pixel_preview.dart';
import '../site/login_dialog.dart';
import '../site/site_share_actions.dart';
import '../site/site_widgets.dart';
import '../site/native_site_shell.dart';
import 'pixel_document.dart';
import 'pixel_image.dart';
import 'pixel_session.dart';

class PixelPage extends StatefulWidget {
  const PixelPage({
    super.key,
    required this.controller,
    this.path = '/pixel',
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<PixelPage> createState() => _PixelPageState();
}

class _PixelPageState extends State<PixelPage> {
  late final PixelSession session;
  final _transform = TransformationController();
  final _focus = FocusNode(),
      _title = TextEditingController(),
      _description = TextEditingController(),
      _note = TextEditingController();
  final _canvasKey = GlobalKey();
  final _notes = <String>[];
  bool _spacePan = false, _galleryOpen = false, _controlsOpen = true;
  int? _pointer;
  Offset? _panLast;
  DateTime? _lastPen;
  double _viewportWidth = 0;
  PixelDocument get doc => session.document;
  @override
  void initState() {
    super.initState();
    session = PixelSession(widget.controller)..addListener(_update);
    unawaited(
      session.initialize(widget.path).then((_) async {
        if (!mounted) return;
        final shared = Uri.parse(widget.path).queryParameters['art'];
        if (shared != null) await _preview({'id': shared});
      }),
    );
  }

  void _update() {
    if (!mounted) return;
    if (_title.text != session.title) _title.text = session.title;
    if (_description.text != session.description) {
      _description.text = session.description;
    }
    setState(() {});
  }

  @override
  void dispose() {
    session.removeListener(_update);
    session.dispose();
    _transform.dispose();
    _focus.dispose();
    _title.dispose();
    _description.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<bool> _login() async {
    if (widget.controller.account != null &&
        !widget.controller.sessionExpired) {
      return true;
    }
    await session.saveDraft();
    if (!mounted) return false;
    await showSiteLogin(context, widget.controller);
    return mounted &&
        widget.controller.account != null &&
        !widget.controller.sessionExpired;
  }

  void _toast(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _toast(e is ApiFailure ? e.message : '操作失败，请重试');
    }
  }

  void _fit() {
    final size =
        (_canvasKey.currentContext?.findRenderObject() as RenderBox?)?.size;
    final scale = size == null
        ? .7
        : (size.width / (doc.width * 6)).clamp(.2, 2.6);
    _transform.value = Matrix4.identity()..scaleByDouble(scale, scale, 1, 1);
  }

  void _zoom(double delta) {
    final old = _transform.value.getMaxScaleOnAxis();
    final value = (old + delta).clamp(.2, 2.6);
    final matrix = _transform.value.clone()
      ..scaleByDouble(value / old, value / old, 1, 1);
    _transform.value = matrix;
    setState(() {});
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space) {
      setState(() => _spacePan = event is! KeyUpEvent);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if ((keys.isControlPressed || keys.isMetaPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyZ) {
      keys.isShiftPressed ? doc.redo() : doc.undo();
      return KeyEventResult.handled;
    }
    if ((keys.isControlPressed || keys.isMetaPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyY) {
      doc.redo();
      return KeyEventResult.handled;
    }
    final tool = {
      LogicalKeyboardKey.keyB: PixelTool.brush,
      LogicalKeyboardKey.keyE: PixelTool.eraser,
      LogicalKeyboardKey.keyF: PixelTool.fill,
      LogicalKeyboardKey.keyV: PixelTool.move,
      LogicalKeyboardKey.keyH: PixelTool.move,
    }[event.logicalKey];
    if (tool != null) {
      doc.chooseTool(tool);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.bracketLeft) {
      setState(() => doc.brushSize = (doc.brushSize - 1).clamp(1, 6));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.bracketRight) {
      setState(() => doc.brushSize = (doc.brushSize + 1).clamp(1, 6));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.minus) {
      _zoom(-.25);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.equal) {
      _zoom(.25);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Offset _scene(PointerEvent event) =>
      _transform.toScene(event.localPosition) / 6;
  void _down(PointerDownEvent event) {
    _focus.requestFocus();
    if (event.kind == PointerDeviceKind.stylus) _lastPen = DateTime.now();
    if (event.kind == PointerDeviceKind.touch &&
        _lastPen != null &&
        DateTime.now().difference(_lastPen!).inMilliseconds < 850) {
      return;
    }
    if (_pointer != null) {
      doc.endStroke();
      _pointer = null;
      return;
    }
    _pointer = event.pointer;
    if (_spacePan ||
        doc.tool == PixelTool.move ||
        event.buttons == kMiddleMouseButton) {
      _panLast = event.localPosition;
      return;
    }
    final p = _scene(event);
    doc.beginStroke(
      p.dx,
      p.dy,
      pressure: event.pressure,
      pen: event.kind == PointerDeviceKind.stylus,
    );
  }

  void _move(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    if (_panLast != null) {
      final delta = event.localPosition - _panLast!;
      final matrix = _transform.value.clone();
      matrix.setTranslationRaw(
        matrix.entry(0, 3) + delta.dx,
        matrix.entry(1, 3) + delta.dy,
        0,
      );
      _transform.value = matrix;
      _panLast = event.localPosition;
      return;
    }
    final p = _scene(event);
    doc.continueStroke(
      p.dx.clamp(-6.0, doc.width + 6.0),
      p.dy.clamp(-6.0, doc.height + 6.0),
      pressure: event.pressure,
      pen: event.kind == PointerDeviceKind.stylus,
    );
  }

  void _end(PointerEvent event) {
    if (_pointer == event.pointer) {
      doc.endStroke();
      _pointer = null;
      _panLast = null;
    }
  }

  Future<void> _importImage() => _safe(() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '图片',
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
          uniformTypeIdentifiers: ['public.image'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
        ),
      ],
    );
    if (file == null) return;
    final revision = doc.revision;
    final rgba = await pixelImageRgba(
      await file.readAsBytes(),
      doc.width,
      doc.height,
    );
    if (!mounted || revision != doc.revision) return;
    doc.importRgba(rgba);
    _toast('图片已转换为像素画');
  });
  Future<void> _export([PixelSnapshot? value, String? name]) => _safe(() async {
    final snapshot = value ?? doc.snapshot;
    final bytes = await pixelPng(snapshot);
    if (!mounted) return;
    if (await exportRoomFile(
      context,
      bytes,
      '${name ?? (_title.text.isEmpty ? '月光像素画' : _title.text)}.png',
      'image/png',
    )) {
      _toast('PNG 已导出');
    }
  });
  Future<void> _draftJson() => _safe(() async {
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(doc.snapshot.toJson())),
    );
    await exportRoomFile(context, bytes, '月光画稿.json', 'application/json');
  });
  Future<void> _restoreJson() => _safe(() async {
    final file = await importRoomFile();
    if (file == null || !mounted) return;
    doc.load(PixelSnapshot.fromJson(mapOf(jsonDecode(file))), history: true);
  });
  Future<void> _preview(Map<String, dynamic> item) => _safe(() async {
    final full = await session.fullArtwork('${item['id']}');
    final snapshot = PixelSnapshot.fromJson(full);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${full['title'] ?? '像素画'}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Text('${full['description'] ?? ''}'),
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: snapshot.width / snapshot.height,
                  child: CustomPaint(painter: PixelPainter(snapshot)),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () =>
                          _export(snapshot, '${full['title'] ?? '像素画'}'),
                      icon: const Icon(Icons.download),
                      label: const SiteText('下载 PNG'),
                    ),
                    TextButton.icon(
                      onPressed: () => _share(full),
                      icon: const Icon(Icons.share),
                      label: const SiteText('分享'),
                    ),
                    if ('${full['author_id']}' == widget.controller.account?.id)
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          unawaited(session.editArtwork('${full['id']}'));
                        },
                        icon: const Icon(Icons.edit),
                        label: const SiteText('编辑作品'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  });
  Future<void> _share(Map<String, dynamic> artwork) => _safe(() async {
    final service = widget.controller.site;
    final actions = service is SiteDataService
        ? SiteShareActions(
            repository: SiteRepository(
              api: service as SiteDataService,
              storage: widget.controller.storage,
              site: () => widget.controller.settings.siteUrl,
              accountId: () => widget.controller.account?.id,
            ),
            canRecordGrowth: () =>
                widget.controller.account != null &&
                !widget.controller.sessionExpired,
          )
        : null;
    final url = Uri.parse(widget.controller.settings.siteUrl)
        .resolve(
          '/pixel?art=${Uri.encodeQueryComponent('${artwork['id']}')}#pixel-art-${artwork['id']}',
        )
        .toString();
    if (actions == null) {
      await Clipboard.setData(ClipboardData(text: url));
    } else {
      await actions.copyLink(url);
    }
    _toast('作品链接已复制');
  });
  Future<void> _publish() async {
    if (await _login()) {
      await session.publish();
      if (mounted) {
        _toast(session.error.isNotEmpty ? session.error : session.notice);
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> artwork) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const SiteText('删除作品？'),
        content: Text('${artwork['title']}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const SiteText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const SiteText('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await session.deleteArtwork('${artwork['id']}');
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: widget.controller,
    title: '月光像素工坊',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SiteText('月光像素工坊', style: Theme.of(context).textTheme.headlineMedium),
        const SiteText('选择工具与颜色，在网格里绘制，再导出或发布你的作品。'),
        const SizedBox(height: 14),
        if (session.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              session.error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (session.notice.isNotEmpty) Text(session.notice),
        LayoutBuilder(
          builder: (context, box) {
            if (!_controlsOpen ||
                box.maxWidth <
                    1000 * (MediaQuery.textScalerOf(context).scale(14) / 14)) {
              return Column(
                children: [
                  _canvasPanel(),
                  const SizedBox(height: 12),
                  if (_controlsOpen) _controls(),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 280, child: _controls()),
                const SizedBox(width: 16),
                Expanded(child: _canvasPanel()),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        _details(),
        const SizedBox(height: 12),
        SiteCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SiteText(
                '制作备忘',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              ..._notes.map(
                (value) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(value),
                ),
              ),
              TextField(
                controller: _note,
                decoration: InputDecoration(
                  hintText: siteTranslate(context, '记下绘画灵感，只在本次页面保留'),
                  suffixIcon: IconButton(
                    onPressed: () {
                      if (_note.text.trim().isNotEmpty) {
                        setState(() {
                          _notes.add(_note.text.trim());
                          _note.clear();
                        });
                      }
                    },
                    icon: const Icon(Icons.add),
                  ),
                ),
                onSubmitted: (value) {
                  if (value.trim().isNotEmpty) {
                    setState(() {
                      _notes.add(value.trim());
                      _note.clear();
                    });
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _gallery(),
        const SizedBox(height: 24),
      ],
    ),
  );
  Widget _canvasPanel() => SiteCard(
    padding: const EdgeInsets.all(12),
    child: Column(
      children: [
        _toolbar(),
        const SizedBox(height: 10),
        Focus(
          focusNode: _focus,
          onKeyEvent: _key,
          child: LayoutBuilder(
            builder: (context, box) {
              if (_viewportWidth != box.maxWidth) {
                _viewportWidth = box.maxWidth;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _fit();
                });
              }
              return Container(
                key: _canvasKey,
                height: (box.maxWidth * 9 / 16).clamp(250.0, 640.0),
                clipBehavior: Clip.hardEdge,
                decoration: BoxDecoration(
                  color: RoomStyle(context).line,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Listener(
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerUp: _end,
                  onPointerCancel: _end,
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      _zoom(event.scrollDelta.dy < 0 ? .1 : -.1);
                    }
                  },
                  child: InteractiveViewer(
                    transformationController: _transform,
                    minScale: .2,
                    maxScale: 2.6,
                    constrained: false,
                    panEnabled: false,
                    scaleEnabled: true,
                    boundaryMargin: const EdgeInsets.all(1500),
                    child: SizedBox(
                      width: doc.width * 6.0,
                      height: doc.height * 6.0,
                      child: Semantics(
                        label: '${doc.width} 乘 ${doc.height} 像素画布',
                        child: CustomPaint(
                          painter: PixelPainter(doc.snapshot, grid: true),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                '${doc.width} × ${doc.height} · 已绘制 ${doc.paintedCount} 像素 · ${doc.palette.length}/64 色',
              ),
            ),
            IconButton(
              onPressed: _fit,
              tooltip: siteTranslate(context, '适应画布'),
              icon: const Icon(Icons.fit_screen),
            ),
            IconButton(
              onPressed: () => _zoom(-.25),
              icon: const Icon(Icons.remove),
            ),
            ValueListenableBuilder<Matrix4>(
              valueListenable: _transform,
              builder: (_, matrix, _) =>
                  Text('${(matrix.getMaxScaleOnAxis() * 100).round()}%'),
            ),
            IconButton(
              onPressed: () => _zoom(.25),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    ),
  );
  Widget _toolbar() => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final entry in [
        (PixelTool.brush, Icons.brush, '画笔 B'),
        (PixelTool.eraser, Icons.cleaning_services, '橡皮 E'),
        (PixelTool.fill, Icons.format_color_fill, '填充 F'),
        (PixelTool.move, Icons.pan_tool, '移动 V'),
      ])
        ChoiceChip(
          label: SiteText(entry.$3),
          avatar: Icon(entry.$2, size: 18),
          selected: doc.tool == entry.$1,
          onSelected: (_) => doc.chooseTool(entry.$1),
        ),
      IconButton(
        onPressed: doc.canUndo ? doc.undo : null,
        tooltip: siteTranslate(context, '撤销 Ctrl/Cmd+Z'),
        icon: const Icon(Icons.undo),
      ),
      IconButton(
        onPressed: doc.canRedo ? doc.redo : null,
        tooltip: siteTranslate(context, '重做 Ctrl/Cmd+Shift+Z'),
        icon: const Icon(Icons.redo),
      ),
      IconButton(
        onPressed: () => setState(() => _controlsOpen = !_controlsOpen),
        tooltip: siteTranslate(context, '颜色与设置'),
        icon: const Icon(Icons.palette),
      ),
      TextButton.icon(
        onPressed: _importImage,
        icon: const Icon(Icons.image),
        label: const SiteText('导入图片'),
      ),
      TextButton.icon(
        onPressed: () => _export(),
        icon: const Icon(Icons.download),
        label: const SiteText('导出 PNG'),
      ),
      TextButton(onPressed: doc.moonExample, child: const SiteText('月亮示例')),
      TextButton(
        onPressed: () async {
          final yes = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const SiteText('清空画布？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const SiteText('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const SiteText('清空'),
                ),
              ],
            ),
          );
          if (yes == true) doc.clear();
        },
        child: const SiteText('清空'),
      ),
    ],
  );
  Widget _controls() => SiteCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SiteText('颜色与设置', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < doc.palette.length; i++)
              Semantics(
                label: '颜色 ${doc.palette[i]}',
                selected: doc.selected == i,
                child: InkWell(
                  onTap: () => doc.chooseColor(i),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: pixelColor(doc.palette[i]),
                      border: Border.all(
                        color: doc.selected == i
                            ? RoomStyle(context).accent
                            : Colors.grey,
                        width: doc.selected == i ? 3 : 1,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () async {
                final color = TextEditingController(
                  text: doc.palette[doc.selected],
                );
                final value = await showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const SiteText('添加颜色'),
                    content: TextField(
                      controller: color,
                      decoration: InputDecoration(
                        labelText: siteTranslate(context, '#RRGGBB'),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const SiteText('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, color.text),
                        child: const SiteText('添加'),
                      ),
                    ],
                  ),
                );
                if (value != null) {
                  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value.trim())) {
                    _toast('请输入 #RRGGBB 颜色');
                  } else {
                    try {
                      doc.addColor(value);
                    } catch (e) {
                      _toast('$e');
                    }
                  }
                }
                color.dispose();
              },
              icon: const Icon(Icons.add),
              label: const SiteText('自定义颜色'),
            ),
            const SiteText('画笔大小'),
            DropdownButton<int>(
              value: doc.brushSize,
              items: [
                for (var i = 1; i <= 6; i++)
                  DropdownMenuItem(value: i, child: Text('$i')),
              ],
              onChanged: (v) => setState(() => doc.brushSize = v!),
            ),
            FilterChip(
              label: const SiteText('笔压'),
              selected: doc.pressureEnabled,
              onSelected: (v) => setState(() => doc.pressureEnabled = v),
            ),
            FilterChip(
              label: const SiteText('笔迹稳定'),
              selected: doc.stabilizerEnabled,
              onSelected: (v) => setState(() => doc.stabilizerEnabled = v),
            ),
            const SiteText('网格'),
            DropdownButton<(int, int)>(
              value: (doc.width, doc.height),
              items: [
                for (final size in pixelCanvasPresets)
                  DropdownMenuItem(
                    value: size,
                    child: Text('${size.$1}×${size.$2}'),
                  ),
              ],
              onChanged: (v) {
                doc.resize(v!.$1, v.$2);
                _fit();
              },
            ),
            const SiteText('背景'),
            for (final color in [
              '#ffffff',
              '#f7f7f7',
              '#edf8ff',
              '#ffd1e8',
              '#172033',
              '#0b1020',
            ])
              InkWell(
                onTap: () => doc.setBackground(color),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: pixelColor(color),
                    border: Border.all(color: Colors.grey),
                  ),
                ),
              ),
            TextButton(onPressed: _draftJson, child: const SiteText('导出画稿')),
            TextButton(onPressed: _restoreJson, child: const SiteText('导入画稿')),
          ],
        ),
        const SizedBox(height: 8),
        const SiteText(
          '快捷键：B 画笔、E 橡皮、F 填充、V/H 移动；空格拖动；[ ] 笔刷大小；+ − 缩放。触控可双指缩放，触笔支持笔压和防误触。',
        ),
      ],
    ),
  );
  Widget _details() => SiteCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          session.editingId == null ? '完成作品' : '编辑已发布作品',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        TextField(
          controller: _title,
          maxLength: 40,
          decoration: InputDecoration(
            labelText: siteTranslate(context, '作品名称'),
          ),
          onChanged: (v) => session.updateDetails(v, _description.text),
        ),
        TextField(
          controller: _description,
          maxLength: 120,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: siteTranslate(context, '作品描述'),
          ),
          onChanged: (v) => session.updateDetails(_title.text, v),
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              onPressed: session.working ? null : _publish,
              icon: const Icon(Icons.publish),
              label: Text(
                session.working
                    ? '正在保存…'
                    : session.editingId == null
                    ? '发布作品'
                    : '保存更新',
              ),
            ),
            TextButton(
              onPressed: () => unawaited(
                session.saveDraft().then((_) => _toast('画稿已保存在本机')),
              ),
              child: const SiteText('保存画稿'),
            ),
            if (session.editingId != null)
              TextButton(
                onPressed: () => setState(() => session.editingId = null),
                child: const SiteText('另存新作品'),
              ),
          ],
        ),
      ],
    ),
  );
  Widget _gallery() => SiteCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () => setState(() => _galleryOpen = !_galleryOpen),
              icon: Icon(_galleryOpen ? Icons.expand_less : Icons.expand_more),
              label: const SiteText('社区作品'),
            ),
            ChoiceChip(
              label: const SiteText('最新'),
              selected: session.sort == 'latest',
              onSelected: (_) {
                session.sort = 'latest';
                unawaited(session.loadGallery(nextPage: 1));
              },
            ),
            ChoiceChip(
              label: const SiteText('热门'),
              selected: session.sort == 'hot',
              onSelected: (_) {
                session.sort = 'hot';
                unawaited(session.loadGallery(nextPage: 1));
              },
            ),
            FilterChip(
              label: const SiteText('我的作品'),
              selected: session.ownOnly,
              onSelected: (v) async {
                if (v && !await _login()) return;
                session.ownOnly = v;
                await session.loadGallery(nextPage: 1);
              },
            ),
            IconButton(
              onPressed: () => unawaited(session.loadGallery()),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (session.loading) const LinearProgressIndicator(),
        if (_galleryOpen) ...[
          if (session.artworks.isEmpty && !session.loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: SiteText('还没有公开作品，第一缕月光可以从这里开始。'),
            ),
          LayoutBuilder(
            builder: (context, box) {
              final columns = box.maxWidth < 520
                  ? 1
                  : box.maxWidth < 900
                  ? 2
                  : 3;
              final width = (box.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final artwork in session.artworks)
                    SizedBox(
                      width: width,
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            InkWell(
                              onTap: () => _preview(artwork),
                              child: AspectRatio(
                                aspectRatio: 16 / 9,
                                child: HubPixelPreview(artwork: artwork),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${artwork['title']}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    'by ${userDisplayName(artwork, prefix: 'author', fallback: '月读访客')} · ${dateText(artwork['created_at'])}',
                                  ),
                                  Wrap(
                                    spacing: 5,
                                    children: [
                                      TextButton.icon(
                                        onPressed: session.working
                                            ? null
                                            : () async {
                                                if (await _login()) {
                                                  await session.like(artwork);
                                                }
                                              },
                                        icon: Icon(
                                          artwork['viewer_liked'] == true ||
                                                  artwork['viewer_liked'] == 1
                                              ? Icons.favorite
                                              : Icons.favorite_border,
                                        ),
                                        label: Text('${artwork['likes'] ?? 0}'),
                                      ),
                                      IconButton(
                                        onPressed: () => _share(artwork),
                                        tooltip: siteTranslate(context, '分享作品'),
                                        icon: const Icon(Icons.share),
                                      ),
                                      if ('${artwork['author_id']}' ==
                                          widget.controller.account?.id) ...[
                                        IconButton(
                                          onPressed: () => unawaited(
                                            session.editArtwork(
                                              '${artwork['id']}',
                                            ),
                                          ),
                                          tooltip: siteTranslate(
                                            context,
                                            '编辑作品',
                                          ),
                                          icon: const Icon(Icons.edit),
                                        ),
                                        IconButton(
                                          onPressed: () => _delete(artwork),
                                          tooltip: siteTranslate(
                                            context,
                                            '删除作品',
                                          ),
                                          icon: const Icon(
                                            Icons.delete_outline,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: session.page > 1
                    ? () => unawaited(
                        session.loadGallery(nextPage: session.page - 1),
                      )
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${session.page} / ${session.totalPages}'),
              IconButton(
                onPressed: session.page < session.totalPages
                    ? () => unawaited(
                        session.loadGallery(nextPage: session.page + 1),
                      )
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}
