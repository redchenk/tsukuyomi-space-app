import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/site_localization.dart';
import 'site_widgets.dart';

const _groups = <String, List<(String, IconData)>>{
  '房间': [
    ('/room', Icons.chat_bubble_outline),
    ('/room/settings', Icons.tune),
    ('/conversations', Icons.history),
    ('/growth', Icons.favorite_outline),
    ('/live2d', Icons.face),
  ],
  '内容创作': [
    ('/stage', Icons.auto_stories_outlined),
    ('/editor', Icons.edit_note),
    ('/attachments', Icons.attach_file),
    ('/gallery', Icons.photo_library_outlined),
    ('/gallery/manage', Icons.collections),
    ('/pixel', Icons.grid_on),
  ],
  '社区': [
    ('/hub', Icons.home_outlined),
    ('/plaza', Icons.forum_outlined),
    ('/wiki', Icons.menu_book),
    ('/friend-links', Icons.link),
    ('/reality', Icons.public),
    ('/game', Icons.sports_esports_outlined),
  ],
  '账户与设置': [
    ('/user', Icons.person_outline),
    ('/notifications', Icons.notifications_outlined),
  ],
};

/// One menu, route vocabulary and focus behavior across all native pages.
class SiteExploreMenu extends StatefulWidget {
  const SiteExploreMenu({
    super.key,
    required this.onSelected,
    this.currentPath = '',
    this.administrator = false,
    this.actions = const {},
    this.showLabel = false,
  });
  final ValueChanged<String> onSelected;
  final String currentPath;
  final bool administrator;
  final Map<String, String> actions;
  final bool showLabel;
  @override
  State<SiteExploreMenu> createState() => _SiteExploreMenuState();
}

class _SiteExploreMenuState extends State<SiteExploreMenu> {
  final _anchor = GlobalKey();
  final _focus = FocusNode(debugLabel: 'Explore menu');
  bool _open = false;
  ModalRoute<dynamic>? _menuRoute;

  void _dismissMenu() {
    final route = _menuRoute;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
  }

  @override
  void didUpdateWidget(covariant SiteExploreMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_open && oldWidget.administrator != widget.administrator) {
      _dismissMenu();
    }
  }

  @override
  void dispose() {
    _dismissMenu();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _show() async {
    if (_open) return;
    _open = true;
    final size = MediaQuery.sizeOf(context);
    final box = _anchor.currentContext!.findRenderObject()! as RenderBox;
    final position = box.localToGlobal(Offset.zero);
    final items = <String, List<(String, IconData)>>{
      ..._groups,
      '账户与设置': [
        ..._groups['账户与设置']!,
        for (final action in widget.actions.keys)
          (
            action,
            switch (action) {
              'theme' => Icons.dark_mode_outlined,
              'search' => Icons.search,
              'music' => Icons.music_note,
              _ => Icons.language,
            },
          ),
        if (widget.administrator) ...[
          ('/admin', Icons.admin_panel_settings_outlined),
          ('/terminal', Icons.terminal),
        ],
      ],
    };
    Widget menu(BuildContext ctx) {
      _menuRoute = ModalRoute.of(ctx);
      return _MenuContents(
        groups: items,
        currentPath: widget.currentPath,
        actions: widget.actions,
        onSelected: (value) => Navigator.pop(ctx, value),
      );
    }

    final String? selected;
    if (size.width < 960) {
      selected = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
        constraints: BoxConstraints(maxHeight: size.height * .85),
        builder: (ctx) => menu(ctx),
      );
    } else {
      selected = await showGeneralDialog<String>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
        barrierColor: Colors.black.withValues(alpha: .12),
        transitionDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        pageBuilder: (ctx, _, _) => Stack(
          children: [
            Positioned(
              top: (position.dy + box.size.height + 10).clamp(
                12,
                size.height * .3,
              ),
              right: (size.width - position.dx - box.size.width).clamp(
                16,
                size.width - 896,
              ),
              width: 880,
              child: Material(
                elevation: 12,
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: size.height * .72),
                  child: menu(ctx),
                ),
              ),
            ),
          ],
        ),
      );
    }
    _open = false;
    _menuRoute = null;
    if (!mounted) return;
    _focus.requestFocus();
    if (selected != null) widget.onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: _anchor,
    focusNode: _focus,
    tooltip: siteTranslate(context, '探索'),
    onPressed: _show,
    icon: widget.showLabel
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.menu_rounded, size: 17),
              const SizedBox(width: 6),
              SiteText('探索', style: const TextStyle(fontSize: 14)),
              const Icon(Icons.expand_more, size: 16),
            ],
          )
        : const Icon(Icons.menu_rounded),
  );
}

class _MenuContents extends StatelessWidget {
  const _MenuContents({
    required this.groups,
    required this.currentPath,
    required this.actions,
    required this.onSelected,
  });
  final Map<String, List<(String, IconData)>> groups;
  final Map<String, String> actions;
  final String currentPath;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
          FocusScope.of(context).nextFocus(),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          FocusScope.of(context).nextFocus(),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
          FocusScope.of(context).previousFocus(),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          FocusScope.of(context).previousFocus(),
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.pop(context),
    },
    child: FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 800
                ? 4
                : constraints.maxWidth >= 680
                ? 3
                : constraints.maxWidth >= 480
                ? 2
                : 1;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 14,
              children: [
                for (final group in groups.entries)
                  SizedBox(
                    width: width,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          child: SiteText(
                            group.key,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        for (final item in group.value)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: ListTile(
                              autofocus: item == groups.values.first.first,
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              selected:
                                  Uri.tryParse(currentPath)?.path == item.$1,
                              selectedTileColor: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer,
                              leading: Icon(item.$2, size: 20),
                              title: SiteText(
                                actions[item.$1] ?? _label(context, item.$1),
                              ),
                              onTap: () => onSelected(item.$1),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );

  String _label(BuildContext context, String path) => switch (path) {
    '/room/settings' => '房间设置',
    '/gallery/manage' => '画廊管理',
    '/live2d' => 'Live2D 舞台',
    '/admin' => '内容管理',
    '/terminal' => '管理终端',
    _ => siteDestinationLabel(context, path),
  };
}
