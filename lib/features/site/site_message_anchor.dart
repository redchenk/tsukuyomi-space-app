class SiteMessageAnchor {
  const SiteMessageAnchor(this.prefix, this.id);
  final String prefix;
  final String id;

  static SiteMessageAnchor? parse(String route, String fragment) {
    final prefix = route == '/plaza'
        ? 'msg'
        : route.startsWith('/articles/')
        ? 'comment'
        : null;
    if (prefix == null) return null;
    final match = RegExp('^$prefix-([0-9]+)\$').firstMatch(fragment);
    return match == null ? null : SiteMessageAnchor(prefix, match.group(1)!);
  }
}

class SiteAnchorLocation {
  const SiteAnchorLocation({
    required this.rootId,
    required this.page,
    required this.reply,
  });
  final String rootId;
  final int page;
  final bool reply;
}

SiteAnchorLocation? findSiteMessageAnchor(
  List<Map<String, dynamic>> threads,
  String id, {
  int pageSize = 8,
}) {
  for (var index = 0; index < threads.length; index++) {
    final root = threads[index];
    final rootId = '${root['id']}';
    if (rootId == id) {
      return SiteAnchorLocation(
        rootId: rootId,
        page: index ~/ pageSize + 1,
        reply: false,
      );
    }
    if ((root['replies'] as List? ?? []).any(
      (reply) => reply is Map && '${reply['id']}' == id,
    )) {
      return SiteAnchorLocation(
        rootId: rootId,
        page: index ~/ pageSize + 1,
        reply: true,
      );
    }
  }
  return null;
}
