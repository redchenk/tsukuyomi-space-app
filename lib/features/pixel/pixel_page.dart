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
import 'pixel_studio_copy.dart';
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
  bool _spacePan = false,
      _controlsOpen = true,
      _focusMode = false,
      _showGrid = false;
  final _touchStarts = <int, Offset>{};
  Duration? _touchStart, _multiStart;
  int _maxTouches = 0;
  bool _touchMoved = false;
  String label(String key) =>
      (pixelStudioCopy[SiteLocaleScope.maybeOf(context)?.language] ??
      pixelStudioCopy['zh']!)[key]!;
  int? _pointer;
  final _pointers = <int>{};
  bool _gestureBlocked = false;
  Offset? _panLast;
  DateTime? _lastPen;
  Size _viewportSize = Size.zero;
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
    if (size == null || size.isEmpty) return;
    final sx = (size.width - 16) / (doc.width * 6),
        sy = (size.height - 16) / (doc.height * 6);
    final scale = (sx < sy ? sx : sy).clamp(.2, 12.0);
    final x = (size.width - doc.width * 6 * scale) / 2,
        y = (size.height - doc.height * 6 * scale) / 2;
    _transform.value = Matrix4.identity()
      ..setTranslationRaw(x, y, 0)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _zoomTo(double value, [Offset? point]) {
    final old = _transform.value.getMaxScaleOnAxis();
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final pivot =
        point ?? (box == null ? Offset.zero : box.size.center(Offset.zero));
    final ratio = value.clamp(.2, 12.0) / old, current = _transform.value;
    _transform.value = current.clone()
      ..setTranslationRaw(
        pivot.dx + (current.entry(0, 3) - pivot.dx) * ratio,
        pivot.dy + (current.entry(1, 3) - pivot.dy) * ratio,
        0,
      )
      ..scaleByDouble(ratio, ratio, 1, 1);
  }

  void _stepZoom(bool increase, [Offset? point]) {
    const levels = [
      .2,
      .25,
      .33,
      .5,
      .67,
      1.0,
      1.5,
      2.0,
      3.0,
      4.0,
      6.0,
      8.0,
      12.0,
    ];
    final current = _transform.value.getMaxScaleOnAxis();
    final next = increase
        ? levels.firstWhere(
            (x) => x > current + .005,
            orElse: () => levels.last,
          )
        : levels.lastWhere(
            (x) => x < current - .005,
            orElse: () => levels.first,
          );
    _zoomTo(next, point);
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
    final modifier = keys.isControlPressed || keys.isMetaPressed;
    if (modifier && event.logicalKey == LogicalKeyboardKey.digit0) {
      _fit();
      return KeyEventResult.handled;
    }
    if (modifier && event.logicalKey == LogicalKeyboardKey.digit1) {
      _zoomTo(1);
      return KeyEventResult.handled;
    }
    if (modifier && event.logicalKey == LogicalKeyboardKey.keyS) {
      unawaited(session.saveDraft());
      return KeyEventResult.handled;
    }
    if (!modifier && event.logicalKey == LogicalKeyboardKey.keyF ||
        event.logicalKey == LogicalKeyboardKey.escape && _focusMode) {
      setState(() => _focusMode = !_focusMode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.quoteSingle) {
      setState(() => _showGrid = !_showGrid);
      return KeyEventResult.handled;
    }
    final tool = {
      LogicalKeyboardKey.keyB: PixelTool.brush,
      LogicalKeyboardKey.keyE: PixelTool.eraser,
      LogicalKeyboardKey.keyG: PixelTool.fill,
      LogicalKeyboardKey.keyI: PixelTool.picker,
      LogicalKeyboardKey.keyV: PixelTool.move,
      LogicalKeyboardKey.keyH: PixelTool.move,
    }[event.logicalKey];
    if (tool != null) {
      doc.chooseTool(tool);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.bracketLeft) {
      doc.configureBrush(size: doc.brushSize - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.bracketRight) {
      doc.configureBrush(size: doc.brushSize + 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.minus) {
      _stepZoom(false);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.equal) {
      _stepZoom(true);
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
    if (event.kind == PointerDeviceKind.touch) {
      _touchStarts[event.pointer] = event.localPosition;
      if (_touchStarts.length == 1) {
        _touchStart = event.timeStamp;
        _maxTouches = 1;
        _touchMoved = false;
      }
      if (_touchStarts.length == 2 && _multiStart == null) {
        _multiStart = event.timeStamp;
      }
      if (_touchStarts.length > _maxTouches) _maxTouches = _touchStarts.length;
    }
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      if (_touchStart != null &&
          (event.timeStamp - _touchStart!).inMilliseconds > 420) {
        doc.endStroke();
      } else {
        doc.cancelStroke();
      }
      _pointer = null;
      _panLast = null;
      setState(() => _gestureBlocked = true);
    }
    if (_gestureBlocked) return;
    _pointer = event.pointer;
    if (_spacePan ||
        doc.tool == PixelTool.move ||
        event.buttons == kMiddleMouseButton) {
      _panLast = event.localPosition;
      return;
    }
    final p = _scene(event);
    if (HardwareKeyboard.instance.isAltPressed) {
      doc.sample(p.dx, p.dy);
      return;
    }
    doc.beginStroke(
      p.dx,
      p.dy,
      pressure: event.pressure,
      pen: event.kind == PointerDeviceKind.stylus,
    );
  }

  void _move(PointerMoveEvent event) {
    final start = _touchStarts[event.pointer];
    if (start != null && (event.localPosition - start).distance >= 12) {
      _touchMoved = true;
    }
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
    if (_touchStarts.remove(event.pointer) != null) {
      if (event is PointerCancelEvent) _touchMoved = true;
      if (_multiStart != null && _touchStarts.length < 2) {
        if (!_touchMoved &&
            (event.timeStamp - _multiStart!).inMilliseconds < 280) {
          if (_maxTouches >= 3) {
            doc.redo();
          } else {
            doc.undo();
          }
        }
        _multiStart = null;
      }
      if (_touchStarts.isEmpty) _touchStart = null;
    }
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty && _gestureBlocked) {
      setState(() => _gestureBlocked = false);
    }
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
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? const Color(0xff1d1e22) : const Color(0xfff4f4f6);
    final panel = dark ? const Color(0xff25262b) : const Color(0xfffbfbfc);
    return NativeSiteShell(
      controller: widget.controller,
      title: label('appName'),
      onGo: widget.onGo,
      onTheme: widget.onTheme,
      fixedViewport: true,
      showChrome: !_focusMode,
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 860,
              controls = wide && !_focusMode && _controlsOpen;
          return ColoredBox(
            color: background,
            child: Column(
              children: [
                if (!_focusMode)
                  Material(
                    color: panel,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () => _sheet(_details),
                            icon: const Icon(Icons.image_outlined),
                            label: Text(
                              session.title.isEmpty
                                  ? label('draftTitle')
                                  : session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: label('undo'),
                          onPressed: doc.canUndo ? doc.undo : null,
                          icon: const Icon(Icons.undo),
                        ),
                        if (wide)
                          IconButton(
                            tooltip: label('redo'),
                            onPressed: doc.canRedo ? doc.redo : null,
                            icon: const Icon(Icons.redo),
                          ),
                        if (wide) ...[
                          IconButton(
                            tooltip: label('gallery'),
                            onPressed: () => _sheet(_gallery),
                            icon: const Icon(Icons.collections_outlined),
                          ),
                          IconButton(
                            tooltip: label('newCanvas'),
                            onPressed: _newCanvas,
                            icon: const Icon(Icons.note_add_outlined),
                          ),
                          IconButton(
                            tooltip: label('imageImport'),
                            onPressed: _importImage,
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                            ),
                          ),
                          IconButton(
                            tooltip: label('download'),
                            onPressed: () => _export(),
                            icon: const Icon(Icons.download),
                          ),
                        ],
                        IconButton(
                          tooltip: label('filePanel'),
                          onPressed: () => _sheet(_files),
                          icon: const Icon(Icons.more_horiz),
                        ),
                        IconButton.filled(
                          tooltip: label('share'),
                          onPressed: () => _sheet(_details),
                          icon: const Icon(Icons.send_outlined),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                if (session.error.isNotEmpty || session.notice.isNotEmpty)
                  Text(
                    session.error.isNotEmpty ? session.error : session.notice,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                Expanded(
                  child: Row(
                    children: [
                      if (wide)
                        Material(
                          color: panel,
                          child: SizedBox(
                            width: 52,
                            child: SingleChildScrollView(
                              child: Column(children: _tools()),
                            ),
                          ),
                        ),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(child: _canvasViewport()),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  Text('${doc.width} × ${doc.height}'),
                                  const SizedBox(width: 10),
                                  if (wide)
                                    Text(
                                      doc.palette[doc.selected].toUpperCase(),
                                    ),
                                  IconButton(
                                    onPressed: () => _stepZoom(false),
                                    tooltip: '${label('zoom')} −',
                                    icon: const Icon(Icons.remove),
                                  ),
                                  ValueListenableBuilder<Matrix4>(
                                    valueListenable: _transform,
                                    builder: (_, m, _) => TextButton(
                                      onPressed: _fit,
                                      child: Text(
                                        '${(m.getMaxScaleOnAxis() * 100).round()}%',
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () => _stepZoom(true),
                                    tooltip: '${label('zoom')} +',
                                    icon: const Icon(Icons.add),
                                  ),
                                  TextButton(
                                    onPressed: () => _zoomTo(1),
                                    child: const Text('1:1'),
                                  ),
                                  IconButton(
                                    onPressed: _fit,
                                    tooltip: label('fitCanvas'),
                                    icon: const Icon(Icons.fit_screen),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (controls)
                        SizedBox(
                          width:
                              (268 *
                                      MediaQuery.textScalerOf(context)
                                          .scale(14) /
                                      14)
                                  .clamp(268.0, box.maxWidth * .47),
                          child: SingleChildScrollView(child: _controls()),
                        ),
                    ],
                  ),
                ),
                if (!wide)
                  Material(
                    color: panel,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: _tools()),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _canvasViewport() => Focus(
    focusNode: _focus,
    onKeyEvent: _key,
    child: LayoutBuilder(
      builder: (context, box) {
        if (_viewportSize != box.biggest) {
          _viewportSize = box.biggest;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fit();
          });
        }
        return Container(
          key: _canvasKey,
          height: box.maxHeight,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xff141518)
                : const Color(0xffdfe0e5),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Listener(
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _end,
            onPointerCancel: _end,
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _stepZoom(event.scrollDelta.dy < 0, event.localPosition);
              }
            },
            child: InteractiveViewer(
              transformationController: _transform,
              minScale: .2,
              maxScale: 12,
              constrained: false,
              panEnabled: _gestureBlocked,
              scaleEnabled: true,
              boundaryMargin: const EdgeInsets.all(1500),
              child: SizedBox(
                width: doc.width * 6.0,
                height: doc.height * 6.0,
                child: Semantics(
                  label: '${doc.width} 乘 ${doc.height} 像素画布',
                  child: CustomPaint(
                    painter: PixelPainter(doc.snapshot, grid: _showGrid),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  List<Widget> _tools() => [
    for (final entry in [
      (PixelTool.brush, Icons.brush, 'brush'),
      (PixelTool.eraser, Icons.cleaning_services, 'eraser'),
      (PixelTool.fill, Icons.format_color_fill, 'fill'),
      (PixelTool.picker, Icons.colorize, 'picker'),
      (PixelTool.move, Icons.pan_tool_outlined, 'move'),
    ])
      IconButton(
        tooltip: label(entry.$3),
        isSelected: doc.tool == entry.$1,
        style: IconButton.styleFrom(
          backgroundColor: doc.tool != entry.$1
              ? null
              : Theme.of(context).colorScheme.secondaryContainer,
        ),
        onPressed: () => doc.chooseTool(entry.$1),
        icon: Icon(entry.$2, size: 20),
      ),
    IconButton(
      tooltip: label('colorPanel'),
      onPressed: _showControls,
      icon: Icon(
        Icons.circle,
        color: pixelColor(doc.palette[doc.selected]),
        shadows: const [Shadow(blurRadius: 2, color: Colors.grey)],
      ),
    ),
    IconButton(
      tooltip: label('grid'),
      isSelected: _showGrid,
      onPressed: () => setState(() => _showGrid = !_showGrid),
      icon: const Icon(Icons.grid_on_outlined),
    ),
    IconButton(
      tooltip: label(_focusMode ? 'exitFocus' : 'focus'),
      onPressed: () => setState(() => _focusMode = !_focusMode),
      icon: Icon(_focusMode ? Icons.fullscreen_exit : Icons.fullscreen),
    ),
    IconButton(
      tooltip: label('shortcuts'),
      onPressed: () => _sheet(
        () => Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            [
              label('brushHint'),
              label('pickerHint'),
              label('gestureHint'),
              'B / E / G / I / H · F · Ctrl/Cmd+Z',
            ].join('\n'),
          ),
        ),
      ),
      icon: const Icon(Icons.help_outline),
    ),
  ];

  Future<void> _sheet(Widget Function() content) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(ctx).height * .8,
        maxWidth: 760,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(ctx).bottom + 12,
        ),
        child: ListenableBuilder(
          listenable: session,
          builder: (_, _) => content(),
        ),
      ),
    ),
  );
  Future<void> _newCanvas() async {
    var size = (doc.width, doc.height);
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => AlertDialog(
          title: Text(label('newTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label('newHint')),
              DropdownButton<(int, int)>(
                value: size,
                items: [
                  for (final item in pixelCanvasPresets)
                    DropdownMenuItem(
                      value: item,
                      child: Text('${item.$1} × ${item.$2}'),
                    ),
                ],
                onChanged: (v) => refresh(() => size = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(label('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, size),
              child: Text(label('create')),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    doc.load(
      PixelSnapshot(
        width: result.$1,
        height: result.$2,
        pixels: List.filled(result.$1 * result.$2, -1),
        palette: doc.palette,
        background: doc.background,
      ),
      history: true,
    );
    _fit();
  }

  Widget _files() => Wrap(
    spacing: 10,
    runSpacing: 4,
    children: [
      TextButton(
        onPressed: () => _sheet(_gallery),
        child: Text(label('gallery')),
      ),
      TextButton(onPressed: _newCanvas, child: Text(label('newCanvas'))),
      TextButton(onPressed: _importImage, child: Text(label('imageImport'))),
      TextButton(onPressed: () => _export(), child: Text(label('download'))),
      TextButton(onPressed: _draftJson, child: const SiteText('导出画稿')),
      TextButton(onPressed: _restoreJson, child: const SiteText('导入画稿')),
      TextButton(
        onPressed: doc.canRedo ? doc.redo : null,
        child: Text(label('redo')),
      ),
      TextButton(onPressed: doc.moonExample, child: const SiteText('月亮示例')),
      TextButton(
        onPressed: () async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const SiteText('清空画布？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(label('cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const SiteText('清空'),
                ),
              ],
            ),
          );
          if (confirmed == true && mounted) doc.clear();
        },
        child: const SiteText('清空'),
      ),
      TextButton(
        onPressed: () => _sheet(_notesPanel),
        child: Text(label('notesPanel')),
      ),
    ],
  );
  Widget _notesPanel() => StatefulBuilder(
    builder: (context, refresh) => Column(
      children: [
        for (final item in _notes) ListTile(title: Text(item)),
        TextField(
          controller: _note,
          decoration: InputDecoration(
            labelText: label('notesPanel'),
            suffixIcon: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () {
                if (_note.text.trim().isNotEmpty) {
                  refresh(() {
                    _notes.add(_note.text.trim());
                    _note.clear();
                  });
                }
              },
            ),
          ),
        ),
      ],
    ),
  );
  Future<void> _showControls() async {
    if (MediaQuery.sizeOf(context).width >= 860 && !_focusMode) {
      setState(() => _controlsOpen = !_controlsOpen);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: AnimatedBuilder(
          animation: doc,
          builder: (_, _) => SingleChildScrollView(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
            child: _controls(),
          ),
        ),
      ),
    );
  }

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
                for (var i = 1; i <= maxPixelBrushSize; i++)
                  DropdownMenuItem(value: i, child: Text('$i')),
              ],
              onChanged: (v) => doc.configureBrush(size: v),
            ),
            FilterChip(
              label: const SiteText('笔压'),
              selected: doc.pressureEnabled,
              onSelected: (v) => doc.configureBrush(pressure: v),
            ),
            FilterChip(
              label: const SiteText('笔迹稳定'),
              selected: doc.stabilizerEnabled,
              onSelected: (v) => doc.configureBrush(smoothing: v),
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
              '#f4f1ea',
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
        Text(label('gestureHint')),
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
            Text(label('gallery')),
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
        ...[
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
