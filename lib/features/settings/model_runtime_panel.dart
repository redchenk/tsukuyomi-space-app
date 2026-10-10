import 'package:flutter/material.dart';

import '../../core/model_runtime.dart';
import '../../core/models.dart';
import '../../core/site_localization.dart';

class ModelRuntimePanel extends StatefulWidget {
  const ModelRuntimePanel({
    super.key,
    required this.settings,
    required this.onChanged,
  });
  final RoomSettings settings;
  final ValueChanged<Map<String, dynamic>> onChanged;
  @override
  State<ModelRuntimePanel> createState() => _ModelRuntimePanelState();
}

class _ModelRuntimePanelState extends State<ModelRuntimePanel> {
  bool modelScope = true;
  ModelRuntime get runtime => ModelRuntime(widget.settings);
  Map<String, dynamic> get layer =>
      modelScope ? runtime.model : runtime.provider;
  void update(String group, String name, dynamic value) {
    final config = normalizeModelRuntime(
      widget.settings.options['runtimeConfig'],
    );
    final table = config[modelScope ? 'models' : 'providers'] as Map;
    final key = modelScope ? runtime.modelKey : runtime.providerKey;
    final current = Map<String, dynamic>.from(table[key] as Map? ?? {});
    final values = Map<String, dynamic>.from(current[group] as Map? ?? {});
    if (value == null || value == 'inherit') {
      values.remove(name);
    } else {
      values[name] = value;
    }
    current[group] = values;
    table[key] = current;
    final next = normalizeModelRuntime(config);
    ModelRuntime(
      widget.settings.copyWith(
        options: {...widget.settings.options, 'runtimeConfig': next},
      ),
    ).resolveParameters();
    widget.onChanged(next);
  }

  Future<void> edit(String name) async {
    final field = TextEditingController(
      text: '${(layer['parameters'] as Map?)?[name] ?? ''}',
    );
    String error = '';
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: SiteText(modelParameterLabels[name]!),
            content: TextField(
              controller: field,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                hintText: name == 'temperature'
                    ? '0–2'
                    : name == 'topP'
                    ? '0.001–1'
                    : '16–131072',
                errorText: error.isEmpty ? null : error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  update('parameters', name, null);
                  Navigator.pop(context);
                },
                child: const SiteText('恢复默认'),
              ),
              FilledButton(
                onPressed: () {
                  try {
                    final value = num.tryParse(field.text.trim());
                    if (field.text.trim().isNotEmpty && value == null) {
                      throw const ApiFailure('请输入有效数值');
                    }
                    update('parameters', name, value);
                    Navigator.pop(context);
                  } catch (e) {
                    setDialogState(
                      () => error = e is ApiFailure ? e.message : '配置无效',
                    );
                  }
                },
                child: const SiteText('保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      field.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = runtime;
    final resolved = current.resolveParameters();
    final capabilities = current.resolveCapabilities();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const SiteText('模型参数与能力'),
      subtitle: const SiteText(
        '服务商默认 · 单模型覆盖 · 协议字段映射',
        style: TextStyle(fontSize: 11),
      ),
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: SiteText('服务商默认')),
            ButtonSegment(value: true, label: SiteText('当前模型')),
          ],
          selected: {modelScope},
          onSelectionChanged: (v) => setState(() => modelScope = v.first),
        ),
        const SizedBox(height: 12),
        for (final name in modelParameterLabels.keys) ...[
          if (name == 'reasoningEffort' || name == 'reasoningEnabled')
            DropdownButtonFormField<String>(
              key: ValueKey(
                '${current.modelKey}-$modelScope-$name-${(layer['parameters'] as Map?)?[name]}',
              ),
              initialValue:
                  '${(layer['parameters'] as Map?)?[name] ?? 'inherit'}',
              isExpanded: true,
              decoration: InputDecoration(
                labelText: siteTranslate(context, modelParameterLabels[name]!),
              ),
              items: [
                for (final value
                    in name == 'reasoningEnabled'
                        ? ['inherit', 'true', 'false']
                        : ['inherit', 'low', 'medium', 'high'])
                  DropdownMenuItem(
                    value: value,
                    child: SiteText(
                      {
                        'inherit': '自动',
                        'true': '开启',
                        'false': '关闭',
                        'low': '低',
                        'medium': '中',
                        'high': '高',
                      }[value]!,
                    ),
                  ),
              ],
              onChanged: (v) => update(
                'parameters',
                name,
                v == 'inherit'
                    ? null
                    : name == 'reasoningEnabled'
                    ? v == 'true'
                    : v,
              ),
            )
          else
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: SiteText(modelParameterLabels[name]!),
              subtitle: Text('${resolved[name]['value'] ?? '自动'}'),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () => edit(name),
            ),
          DropdownButtonFormField<String>(
            key: ValueKey(
              '${current.modelKey}-$modelScope-mapping-$name-${(layer['mappings'] as Map?)?[name]}',
            ),
            initialValue: '${(layer['mappings'] as Map?)?[name] ?? 'inherit'}',
            isExpanded: true,
            decoration: InputDecoration(
              labelText: siteTranslate(context, '映射字段'),
              isDense: true,
            ),
            items: [
              for (final field
                  in current
                      .allowedMappings(name)
                      .where(
                        (v) =>
                            !(current.protocol == 'anthropic' &&
                                name == 'maxOutputTokens' &&
                                v == 'omit'),
                      ))
                DropdownMenuItem(
                  value: field,
                  child: field == 'inherit'
                      ? const SiteText('自动')
                      : field == 'omit'
                      ? const SiteText('不发送')
                      : Text(field),
                ),
            ],
            onChanged: (v) => update('mappings', name, v),
          ),
          const SizedBox(height: 18),
        ],
        if (modelScope) ...[
          const SiteText(
            '能力覆盖：未知能力仍可尝试，明确关闭的能力不会发送。',
            style: TextStyle(fontSize: 12),
          ),
          for (final name in modelCapabilityLabels.keys)
            DropdownButtonFormField<String>(
              key: ValueKey(
                '${current.modelKey}-cap-$name-${(layer['capabilities'] as Map?)?[name]}',
              ),
              initialValue:
                  '${(layer['capabilities'] as Map?)?[name] ?? 'inherit'}',
              isExpanded: true,
              decoration: InputDecoration(
                labelText: siteTranslate(context, modelCapabilityLabels[name]!),
                helperText:
                    '${siteTranslate(context, '服务商声明')}：${capabilities[name]['declared'] ?? siteTranslate(context, '未知')}',
              ),
              items: const [
                DropdownMenuItem(value: 'inherit', child: SiteText('自动')),
                DropdownMenuItem(value: 'true', child: SiteText('支持')),
                DropdownMenuItem(value: 'false', child: SiteText('不支持')),
              ],
              onChanged: (v) => update(
                'capabilities',
                name,
                v == 'inherit' ? null : v == 'true',
              ),
            ),
        ],
        const SizedBox(height: 20),
      ],
    );
  }
}
