/// Matches backend/services/friend-links.js; server reachability and avatar
/// checks remain authoritative and are surfaced without clearing the form.
class FriendLinkApplication {
  static const limits = {
    'name': 40,
    'description': 160,
    'note': 300,
    'url': 2048,
    'avatar_url': 2048,
    'backlink_url': 2048,
  };
  static String normalizeText(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');
  static String? validate(String key, String value) {
    final raw = value.trim(), normalized = normalizeText(value);
    if (key == 'name' || key == 'description' || key == 'note') {
      if (key == 'note' && raw.isEmpty) return null;
      final min = key == 'name'
          ? 2
          : key == 'description'
          ? 6
          : 1;
      if (normalized.length < min ||
          normalized.length > limits[key]! ||
          RegExp(r'[\x00-\x1f\x7f<>]').hasMatch(normalized)) {
        return switch (key) {
          'name' => '站点名称需为 2-40 个字符',
          'description' => '站点简介需为 6-160 个字符',
          _ => '补充说明格式无效或超过 300 个字符',
        };
      }
      return null;
    }
    if ((key == 'avatar_url' || key == 'backlink_url') && raw.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    final valid =
        uri != null &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        (key == 'avatar_url'
            ? uri.scheme == 'https'
            : ['http', 'https'].contains(uri.scheme)) &&
        raw.length <= limits[key]! &&
        !RegExp(r'[\x00-\x1f\x7f]').hasMatch(raw);
    if (valid) return null;
    return switch (key) {
      'avatar_url' => '头像链接必须是有效的 HTTPS 地址',
      'backlink_url' => '回链地址格式无效',
      _ => '请填写有效的 HTTP(S) 站点地址',
    };
  }

  static Map<String, dynamic> body(Map<String, String> fields) => {
    for (final key in limits.keys)
      key: ['name', 'description', 'note'].contains(key)
          ? normalizeText(fields[key] ?? '')
          : (fields[key] ?? '').trim(),
  };
}
