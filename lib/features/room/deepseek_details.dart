import '../../core/site_localization.dart';

import 'package:flutter/material.dart';

import '../../core/deepseek.dart';
import '../site/site_widgets.dart';
import 'room_controller.dart';

class DeepseekDetails extends StatelessWidget {
  const DeepseekDetails({
    super.key,
    required this.controller,
    this.contextData,
    this.live = false,
  });
  final RoomController controller;
  final Map<String, dynamic>? contextData;
  final bool live;
  @override
  Widget build(BuildContext context) {
    final reply = live ? controller.deepseekReply : null;
    final meta = live ? reply?.metadata : contextData?['assistant'] as Map?;
    final files = contextData?['user']?['files'] as List? ?? [];
    final sources = Deepseek.sources(meta);
    if (files.isEmpty &&
        sources.isEmpty &&
        reply == null &&
        meta?['truncated'] != true) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (files.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                for (final file in files)
                  Chip(
                    avatar: const Icon(Icons.description_outlined, size: 16),
                    label: Text('${file['name']}'),
                  ),
              ],
            ),
          if (reply != null && reply.reasoning.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const SiteText('深度思考'),
              children: [SelectableText(reply.reasoning)],
            ),
          if (reply != null && reply.events.isNotEmpty)
            SiteText('已执行 ${reply.events.length} 个搜索 / 阅读步骤'),
          if (sources.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: SiteText('参考来源 · ${sources.length}'),
              children: [
                for (final source in sources)
                  ListTile(
                    dense: true,
                    title: Text(source['title']!),
                    subtitle: Text(
                      source['url']!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.open_in_new, size: 16),
                    onTap: () => openSiteLink(
                      controller.settings.siteUrl,
                      source['url']!,
                    ),
                  ),
              ],
            ),
          if (meta?['truncated'] == true) const SiteText('本次回复达到长度限制，可继续提问。'),
        ],
      ),
    );
  }
}
