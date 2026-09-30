import 'models.dart';

/// The routes with an actual native implementation. Keep web-only destinations
/// out of this list so they cannot accidentally display a different page.
const nativeSiteRoutes = {
  '/',
  '/room',
  '/room/settings',
  '/live2d',
  '/hub',
  '/stage',
  '/plaza',
  '/growth',
  '/user',
  '/conversations',
  '/notifications',
  '/wiki',
  '/gallery',
  '/gallery/manage',
  '/pixel',
  '/friend-links',
  '/friend-links/apply',
  '/reality',
  '/editor',
  '/attachments',
  '/admin',
  '/terminal',
  '/game',
  '/login',
  '/register',
};

String? nativeSitePath(Uri uri) {
  if (uri.hasScheme || uri.hasAuthority) return null;
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.isEmpty) path = '/';
  var query = uri.query;
  if (path == '/user-center') path = '/user';
  if (path == '/room-settings') path = '/room/settings';
  if ({'/', '/access', '/access.html', '/index.html'}.contains(path)) {
    path = '/room';
  }
  if (path == '/arena' || path.startsWith('/arena/')) path = '/pixel';
  if (path == '/article') {
    final id = uri.queryParameters['id']?.trim() ?? '';
    if (id.isEmpty || id.contains('/')) return null;
    path = '/articles/${Uri.encodeComponent(id)}';
    final parameters = Map<String, String>.from(uri.queryParameters)
      ..remove('id');
    query = Uri(queryParameters: parameters.isEmpty ? null : parameters).query;
  }
  final parts = Uri.parse(path).pathSegments;
  final article =
      parts.length >= 2 &&
      parts.length <= 3 &&
      parts.first == 'articles' &&
      parts[1].isNotEmpty &&
      !parts[1].contains('/');
  final wiki =
      parts.length == 3 &&
      parts.first == 'wiki' &&
      {'characters', 'terms'}.contains(parts[1]) &&
      parts[2].isNotEmpty &&
      !parts[2].contains('/');
  final user =
      parts.length == 2 &&
      parts.first == 'users' &&
      parts[1].isNotEmpty &&
      !parts[1].contains('/');
  final shared =
      parts.length == 3 &&
      parts[0] == 'room' &&
      parts[1] == 'shared' &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(parts[2]);
  if (!nativeSiteRoutes.contains(path) &&
      !article &&
      !wiki &&
      !user &&
      !shared) {
    return null;
  }
  return Uri.parse(path)
      .replace(
        query: query.isEmpty ? null : query,
        fragment: uri.fragment.isEmpty ? null : uri.fragment,
      )
      .toString();
}

class SiteTarget {
  const SiteTarget(this.url, this.nativePath);
  final Uri url;
  final String? nativePath;
}

SiteTarget resolveSiteTarget(String site, String value) {
  final base = endpointUri(site);
  final url = base.resolve(value.trim());
  if (!['https', 'http'].contains(url.scheme) ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty) {
    throw const FormatException('暂不支持打开此链接');
  }
  final sameOrigin =
      url.scheme == base.scheme &&
      url.host == base.host &&
      url.port == base.port;
  final local = Uri.parse(url.path).replace(
    query: url.hasQuery ? url.query : null,
    fragment: url.hasFragment ? url.fragment : null,
  );
  return SiteTarget(url, sameOrigin ? nativeSitePath(local) : null);
}
