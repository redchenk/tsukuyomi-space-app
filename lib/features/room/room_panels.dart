import 'package:flutter/material.dart';

import 'room_controller.dart';
import 'room_style.dart';
import 'room_diary_panel.dart';

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
  final _note = TextEditingController(),
      _nickname = TextEditingController(),
      _signature = TextEditingController();
  String _status = '', _noteScope = '';
  bool _loading = true, _saving = false;
  @override
  void initState() {
    super.initState();
    _nickname.text = '${widget.controller.workspace.profile['nickname'] ?? ''}';
    _signature.text =
        '${widget.controller.workspace.profile['signature'] ?? ''}';
    _loadNote();
  }

  Future<void> _loadNote() async {
    _noteScope = '${widget.controller.scope}.room-note';
    try {
      final legacy = await widget.controller.storage.draft(_noteScope);
      final text = widget.controller.workspace.note.isEmpty
          ? legacy
          : widget.controller.workspace.note;
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
      await widget.controller.workspace.saveNote(_note.text);
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
    _nickname.dispose();
    _signature.dispose();
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
          TextField(
            controller: _nickname,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: '昵称',
              hintText: '你希望八千代怎么称呼你',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _signature,
            maxLength: 300,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '个性签名'),
          ),
          const SizedBox(height: 12),
          Text(_status.isEmpty ? '资料保存在此设备' : _status),
          FilledButton(
            onPressed: _saving
                ? null
                : () async {
                    final scope = widget.controller.scope;
                    setState(() => _saving = true);
                    try {
                      await widget.controller.workspace.saveProfile(
                        _nickname.text,
                        _signature.text,
                      );
                      if (mounted && scope == widget.controller.scope) {
                        setState(() => _status = '资料已保存');
                      }
                    } catch (_) {
                      if (mounted) setState(() => _status = '保存失败，请重试');
                    } finally {
                      if (mounted) setState(() => _saving = false);
                    }
                  },
            child: const Text('保存资料'),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: widget.onSettings,
            child: const Text('房间与角色设置'),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [RoomDiaryPanel(controller: widget.controller)],
    );
  }
}
