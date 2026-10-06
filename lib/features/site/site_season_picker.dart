import 'package:flutter/material.dart';

import '../../core/season_theme.dart';
import '../../core/site_localization.dart';

Future<void> showSiteSeasonPicker(BuildContext context) async {
  final controller = SiteSeasonScope.maybeOf(context);
  if (controller == null) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => AlertDialog(
        title: const SiteText('季节主题'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in const {
                  'auto': '跟随季节',
                  'spring': '樱花',
                  'summer': '夏日',
                  'autumn': '红叶',
                  'winter': '冬雪',
                }.entries)
                  ListTile(
                    title: SiteText(entry.value),
                    selected: controller.mode == entry.key,
                    trailing: controller.mode == entry.key
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => _save(context, controller.select(entry.key)),
                  ),
                const Divider(),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final south in [false, true])
                      ChoiceChip(
                        label: SiteText(south ? '南半球' : '北半球'),
                        selected: controller.south == south,
                        onSelected: (_) => _save(
                          context,
                          controller.select(controller.mode, southern: south),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const SiteText('仅保存到本机，深浅主题独立切换。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const SiteText('关闭'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _save(BuildContext context, Future<bool> save) async {
  if (!await save && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: SiteText('主题已切换，暂时无法保存到本机')));
  }
}
