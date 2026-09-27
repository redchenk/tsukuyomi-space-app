import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'room_controller.dart';
import 'room_style.dart';

class RoomUtilityPanel extends StatefulWidget {
  const RoomUtilityPanel({
    super.key,
    required this.panel,
    required this.controller,
    required this.onOpenWebsite,
    required this.onSettings,
  });
  final String panel;
  final RoomController controller;
  final VoidCallback onOpenWebsite, onSettings;
  @override
  State<RoomUtilityPanel> createState() => _RoomUtilityPanelState();
}

class _RoomUtilityPanelState extends State<RoomUtilityPanel> {
  final _note = TextEditingController();
  String _status = '', _noteScope = '';
  bool _loading = true, _saving = false;
  @override
  void initState() {
    super.initState();
    _loadNote();
  }

  Future<void> _loadNote() async {
    _noteScope = '${widget.controller.scope}.room-note';
    try {
      final text = await widget.controller.storage.draft(_noteScope);
      if (mounted) {
        setState(() {
          _note.text = text;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = '便签读取失败';
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.controller.storage.saveDraft(_noteScope, _note.text);
      if (mounted) setState(() => _status = '已保存在此设备');
    } catch (_) {
      if (mounted) setState(() => _status = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    if (widget.panel == '便签') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text(
              '随手记下这一刻',
              style: TextStyle(fontFamily: RoomStyle.serif, fontSize: 22),
            ),
          ),
          Expanded(
            child: TextField(
              key: const Key('room-note'),
              controller: _note,
              enabled: !_loading && !_saving,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(hintText: '想留住的话、突然冒出的念头…'),
              onChanged: (_) => setState(() => _status = '尚未保存'),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _status.isEmpty ? '本机便签，不同步到网站' : _status,
                  style: TextStyle(fontSize: 11, color: p.muted),
                ),
              ),
              FilledButton(
                onPressed: _loading || _saving ? null : _save,
                child: const Text('保存便签'),
              ),
            ],
          ),
        ],
      );
    }
    if (widget.panel == '资料') {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        children: [
          const Center(child: CharacterAvatar(size: 88, radius: 24)),
          const SizedBox(height: 18),
          const Text(
            '月见八千代',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: RoomStyle.serif, fontSize: 25),
          ),
          const SizedBox(height: 8),
          Text(
            '在这里，陪着你',
            textAlign: TextAlign.center,
            style: TextStyle(color: p.muted),
          ),
          const SizedBox(height: 32),
          ListTile(
            title: const Text('角色'),
            subtitle: const Text('八千代 · 默认角色'),
            leading: const Icon(CupertinoIcons.person),
          ),
          ListTile(
            title: const Text('对话模式'),
            subtitle: Text(
              widget.controller.settings.demo
                  ? '离线演示'
                  : widget.controller.settings.model,
            ),
            leading: const Icon(CupertinoIcons.chat_bubble_2),
          ),
          ListTile(
            title: const Text('账号'),
            subtitle: Text(widget.controller.account?.username ?? '尚未登录'),
            leading: const Icon(CupertinoIcons.person_crop_circle),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: widget.onSettings,
            child: const Text('房间与角色设置'),
          ),
        ],
      );
    }
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.book, size: 36, color: p.accent),
              const SizedBox(height: 22),
              const Text(
                '把相处的片刻，留成日记',
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: RoomStyle.serif, fontSize: 22),
              ),
              const SizedBox(height: 12),
              Text(
                '网站里的日记还没有接入此应用。\n你可以前往网站继续查看和书写。',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted, fontSize: 13, height: 1.8),
              ),
              const SizedBox(height: 22),
              OutlinedButton.icon(
                onPressed: widget.onOpenWebsite,
                icon: const Icon(CupertinoIcons.arrow_up_right, size: 16),
                label: const Text('在网站打开日记'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
