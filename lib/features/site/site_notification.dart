/// The website publishes `unread` and `read_at`, not `is_read`.
class SiteNotification {
  SiteNotification(Map<String, dynamic> value) : data = Map.of(value);

  final Map<String, dynamic> data;
  String get id => '${data['id'] ?? ''}';
  String get title => '${data['title'] ?? ''}';
  String get content => '${data['content'] ?? ''}';
  String get link => '${data['link'] ?? ''}';
  bool get unread {
    final explicit = _boolean(data['unread']);
    if (explicit != null) return explicit;
    if (data.containsKey('read_at')) {
      return data['read_at'] == null || '${data['read_at']}'.isEmpty;
    }
    // Old local snapshots can still contain the previous field.
    return _boolean(data['is_read']) == false;
  }

  Map<String, dynamic> read({Map<String, dynamic>? response}) => {
    ...data,
    ...?response,
    'unread': false,
    'read_at':
        response?['read_at'] ??
        data['read_at'] ??
        DateTime.now().toUtc().toIso8601String(),
  };

  static bool? _boolean(dynamic value) => switch (value) {
    true || 1 || '1' || 'true' => true,
    false || 0 || '0' || 'false' => false,
    _ => null,
  };
}

int notificationUnreadCount(dynamic value, Iterable<SiteNotification> items) {
  final count = value is num ? value.toInt() : int.tryParse('$value');
  return count == null
      ? items.where((item) => item.unread).length
      : count.clamp(0, 0x7fffffff);
}
