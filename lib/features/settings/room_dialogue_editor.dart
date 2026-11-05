import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/room_archive.dart';
import '../../core/room_chat_settings.dart';
import '../../core/room_files.dart';
import '../../core/room_reference.dart';
import '../../core/site_localization.dart';

class RoomDialogueEditor extends StatefulWidget {
  const RoomDialogueEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;
  @override
  State<RoomDialogueEditor> createState() => _RoomDialogueEditorState();
}

class _RoomDialogueEditorState extends State<RoomDialogueEditor> {
  late Map<String, dynamic> draft;
  String feedback = '', previewMessage = '晚上好，今天有什么想做的？';
  int revision = 0;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    draft = RoomChatSettings.normalize(widget.value);
  }

  @override
  void didUpdateWidget(covariant RoomDialogueEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(widget.value) != jsonEncode(oldWidget.value) &&
        jsonEncode(widget.value) != jsonEncode(draft)) {
      draft = RoomChatSettings.normalize(widget.value);
      revision++;
    }
  }

  void change(VoidCallback edit) {
    setState(edit);
    widget.onChanged(draft);
  }

  Widget field(
    Map<String, dynamic> target,
    String key,
    String label,
    int limit,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      key: ValueKey('$revision:${identityHashCode(target)}:$key'),
      initialValue: '${target[key] ?? ''}',
      minLines: 2,
      maxLines: 5,
      maxLength: limit,
      decoration: InputDecoration(labelText: siteTranslate(context, label)),
      onChanged: (value) => change(() => target[key] = value),
    ),
  );
  Future<void> importCard() async {
    setState(() => loading = true);
    try {
      final raw = await importRoomFile();
      if (raw == null || !mounted) return;
      final card = RoomChatSettings.importCard(raw);
      change(() {
        draft['reference'] = card;
        draft['referenceEnabled'] = true;
        draft['worldBookEnabled'] = true;
        revision++;
        feedback = '已载入预览并开启角色卡与世界书，保存后用于聊天。';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => feedback = error is FormatException
              ? error.message
              : '无法导入角色卡，请检查 JSON 文件',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = draft['reference'] as Map<String, dynamic>?;
    final entries = card == null
        ? <Map<String, dynamic>>[]
        : (card['character_book']['entries'] as List)
              .cast<Map<String, dynamic>>();
    final match = RoomChatSettings.selectWorldBook(
      card == null ? {} : jsonMap(card['character_book']),
      previewMessage,
      [],
      '${draft['spoiler']}',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SiteText(
          '角色卡与世界书',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const SiteText(
          '借鉴表达与场景，不替换八千代身份。不会执行扩展脚本，也不会把示例当作经历过的对话。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: ValueKey('spoiler:$revision'),
          initialValue: '${draft['spoiler']}',
          isExpanded: true,
          decoration: InputDecoration(
            labelText: siteTranslate(context, '剧透偏好'),
          ),
          items: [
            DropdownMenuItem(value: 'avoid', child: SiteText('不主动剧透，问到时再聊')),
            DropdownMenuItem(value: 'allow', child: SiteText('可以聊结局与身世')),
          ],
          onChanged: (value) => change(() => draft['spoiler'] = value),
        ),
        const SizedBox(height: 16),
        field(draft, 'userPersona', '希望八千代怎样认识你', 800),
        field(draft, 'scenario', '今天的聊天场景', 1200),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: loading ? null : importCard,
              child: const SiteText('导入参考角色卡'),
            ),
            TextButton(
              onPressed: loading
                  ? null
                  : () async {
                      await exportRoomFile(
                        context,
                        Uint8List.fromList(
                          utf8.encode(
                            jsonEncode(
                              RoomReference.data['dialogueBuiltinCard'],
                            ),
                          ),
                        ),
                        'yachiyo-post-film-v3.character.json',
                        'application/json',
                      );
                    },
              child: const SiteText('导出八千代角色卡'),
            ),
          ],
        ),
        if (card != null) ...[
          const SizedBox(height: 12),
          Text(
            '${card['name']}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const SiteText('在聊天中参考这张卡'),
            value: draft['referenceEnabled'] == true,
            onChanged: (value) =>
                change(() => draft['referenceEnabled'] = value),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const SiteText('启用卡片世界书'),
            subtitle: Text('${entries.length}'),
            value: draft['worldBookEnabled'] == true,
            onChanged: (value) =>
                change(() => draft['worldBookEnabled'] = value),
          ),
          const SiteText(
            '两个开关分别生效，保存后用于下一轮聊天。世界书按关键词匹配，“始终参考”的条目会直接带入。',
            style: TextStyle(fontSize: 12),
          ),
          ExpansionTile(
            title: const SiteText('编辑参考角色卡'),
            maintainState: true,
            children: [
              field(card, 'description', '参考说明', 3000),
              field(card, 'personality', '可借鉴的性格表达', 3000),
              field(card, 'scenario', '参考场景', 2000),
              if ('${card['mes_example']}'.isNotEmpty)
                ExpansionTile(
                  title: const SiteText('查看示例（不会发送给模型）'),
                  children: [SelectableText('${card['mes_example']}')],
                ),
            ],
          ),
          ExpansionTile(
            title: const SiteText('检查世界书条目'),
            maintainState: true,
            children: [
              for (final entry in entries)
                ExpansionTile(
                  key: ValueKey('$revision:entry:${entry['id']}'),
                  title: Text(
                    '${entry['name']}'.isEmpty
                        ? '${entry['id']}'
                        : '${entry['name']}',
                  ),
                  maintainState: true,
                  children: [
                    SwitchListTile.adaptive(
                      title: const SiteText('启用此条目'),
                      value: entry['enabled'] == true,
                      onChanged: (value) =>
                          change(() => entry['enabled'] = value),
                    ),
                    Text(
                      entry['constant'] == true
                          ? siteTranslate(context, '始终参考')
                          : (entry['keys'] as List).join('、'),
                    ),
                    SwitchListTile.adaptive(
                      title: const SiteText('包含结局或身世剧透'),
                      value: entry['spoiler'] == true,
                      onChanged: (value) =>
                          change(() => entry['spoiler'] = value),
                    ),
                    field(entry, 'content', '世界书内容', 2000),
                  ],
                ),
            ],
          ),
          TextButton(
            onPressed: () => change(() {
              draft['reference'] = null;
              draft['referenceEnabled'] = false;
              draft['worldBookEnabled'] = false;
              revision++;
            }),
            child: const SiteText('移除参考卡'),
          ),
        ],
        ExpansionTile(
          title: const SiteText('预览本轮会参考什么'),
          children: [
            TextFormField(
              initialValue: previewMessage,
              decoration: InputDecoration(
                labelText: siteTranslate(context, '试写一句话'),
              ),
              onChanged: (value) => setState(() => previewMessage = value),
            ),
            const SizedBox(height: 12),
            SiteText(draft['referenceEnabled'] == true ? '角色卡已启用' : '角色卡未启用'),
            SiteText(draft['worldBookEnabled'] == true ? '世界书已启用' : '世界书未启用'),
            if (draft['worldBookEnabled'] == true) ...[
              for (final entry in match.selected)
                ListTile(
                  title: Text('${entry['name']}'),
                  subtitle: Text('${entry['content']}'),
                ),
              if (match.omitted.isNotEmpty) const SiteText('部分条目因篇幅限制省略'),
            ],
            const SiteText('仅在本机检查编排，不调用模型，不保存聊天。'),
          ],
        ),
        if (feedback.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Semantics(liveRegion: true, child: SiteText(feedback)),
          ),
        const SiteText(
          '只保存在当前账号的这台设备中。保存后用于下一轮聊天。',
          style: TextStyle(fontSize: 12),
        ),
        const Divider(height: 32),
      ],
    );
  }
}
