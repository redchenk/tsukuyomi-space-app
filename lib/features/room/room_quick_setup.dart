import 'package:flutter/material.dart';

import '../../core/site_localization.dart';
import '../../core/models.dart';
import 'room_controller.dart';

class RoomQuickSetup extends StatefulWidget {
  const RoomQuickSetup({super.key, required this.controller});
  final RoomController controller;
  @override
  State<RoomQuickSetup> createState() => _RoomQuickSetupState();
}

class _RoomQuickSetupState extends State<RoomQuickSetup> {
  late final _url = TextEditingController(
    text: widget.controller.settings.llmUrl,
  );
  late final _model = TextEditingController(
    text: widget.controller.settings.model,
  );
  final _key = TextEditingController();
  bool _saving = false;
  String _error = '';
  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      endpointUri(_url.text.trim());
      if (_model.text.trim().isEmpty) throw const ApiFailure('请填写模型名称');
      await widget.controller.configure(
        widget.controller.settings.copyWith(
          llmUrl: _url.text.trim(),
          model: _model.text.trim(),
          apiKey: _key.text.trim().isEmpty
              ? widget.controller.settings.apiKey
              : _key.text.trim(),
          demo: false,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('room-quick-setup'),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(16),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 250),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SiteText(
                '连接模型，开始聊天',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _url,
                decoration: const InputDecoration(labelText: 'API URL'),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _model,
                      decoration: InputDecoration(
                        labelText: siteTranslate(context, '模型名称'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _key,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'API Key'),
                    ),
                  ),
                ],
              ),
              if (_error.isNotEmpty) Text(_error),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: SiteText(_saving ? '正在保存…' : '保存并开始聊天'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
