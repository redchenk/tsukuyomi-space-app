import 'package:flutter/material.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import '../../core/site_client.dart';
import '../../core/site_localization.dart';
import '../site/site_widgets.dart';
import 'room_controller.dart';
import 'room_page.dart';

class SharedRoomPage extends StatefulWidget {
  const SharedRoomPage({
    super.key,
    required this.controller,
    required this.shareKey,
    required this.onGo,
    this.onTheme,
    this.loadNative = true,
    this.modelLoader,
  });
  final RoomController controller;
  final String shareKey;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final bool loadNative;
  final Future<Live2DModel> Function()? modelLoader;
  @override
  State<SharedRoomPage> createState() => _SharedRoomPageState();
}

class _SharedRoomPageState extends State<SharedRoomPage> {
  bool _loading = true;
  String _error = '';
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_ready);
    _ready();
  }

  String? _loadedOwner;
  String get _owner =>
      '${widget.controller.settings.siteUrl}|${widget.controller.scope}|${widget.controller.account?.id}|${widget.controller.sessionExpired}';
  void _ready() {
    if (!widget.controller.canSend || _loadedOwner == _owner) return;
    _loadedOwner = _owner;
    _load();
  }

  @override
  void didUpdateWidget(covariant SharedRoomPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_ready);
      widget.controller.addListener(_ready);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.shareKey != widget.shareKey) {
      _loadedOwner = null;
      _ready();
    }
  }

  Future<void> _load() async {
    final epoch = ++_epoch, owner = _owner;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final response = await (widget.controller.site as SiteDataService)
          .request(
            widget.controller.settings.siteUrl,
            'GET',
            '/api/room/shares/${Uri.encodeComponent(widget.shareKey)}',
          );
      if (!mounted || epoch != _epoch || owner != _owner) {
        return;
      }
      widget.controller.showSharedConversation(mapOf(response['data']));
    } catch (e) {
      if (mounted && epoch == _epoch && owner == _owner) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _epoch++;
    widget.controller.removeListener(_ready);
    widget.controller.leaveSharedConversation(
      shareKey: widget.shareKey,
      notify: false,
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.controller.workspace.changed(),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _error.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(title: const SiteText('公开对话片段')),
        body: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error),
                    TextButton(onPressed: _load, child: const SiteText('重试')),
                    TextButton(
                      onPressed: () => widget.onGo('/room'),
                      child: const SiteText('返回私人居所'),
                    ),
                  ],
                ),
        ),
      );
    }
    return RoomPage(
      controller: widget.controller,
      onNavigate: widget.onGo,
      onToggleTheme: widget.onTheme,
      loadNative: widget.loadNative,
      modelLoader: widget.modelLoader,
    );
  }
}
