import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../drift/drift_submissions.dart';
import '../room/room_controller.dart';
import '../site/site_widgets.dart';
import 'chatroom_copy.dart';

class ChannelDraft {
  String text = '';
  int? replyTo;
  bool sending = false;
  Map<String, dynamic>? pending;
}

class ChatroomSession extends ChangeNotifier {
  ChatroomSession(this.room, String? requested)
    : channel = channelIds.contains(requested) ? requested! : channelIds.first {
    _identity = _owner;
    room.addListener(_identityChanged);
  }

  final RoomController room;
  String channel, status = 'connecting', feedback = '';
  final messages = SplayTreeMap<int, Map<String, dynamic>>();
  final _drafts = <String, ChannelDraft>{};
  final unread = <String>{};
  List<Map<String, dynamic>> members = [];
  String? get user => room.sessionExpired ? null : room.account?.id;
  bool get moderator =>
      user != null && {'admin', 'super_admin'}.contains(room.account?.role);
  ChannelDraft get draft => _drafts.putIfAbsent(channel, ChannelDraft.new);
  String get _owner => '${room.settings.siteUrl}|${user ?? ''}';
  late String _identity;
  bool older = false, loadingOlder = false, rewarded = false;
  bool _active = false, _closed = false;
  int _epoch = 0, _pollVersion = 0;
  Timer? _timer, _probe;
  Completer<void>? _stopStream;
  bool _streaming = false, _snapshot = false;
  int _identityVersion = 0, _rewardRevision = 0;
  String _cursor = '';

  Future<Map<String, dynamic>> _request(
    String path, [
    String method = 'GET',
    Map<String, dynamic>? payload,
  ]) async {
    final owner = _identityVersion;
    final response = await (room.site as SiteDataService).request(
      room.settings.siteUrl,
      method,
      '/api/chatroom/$path',
      payload,
    );
    if (_closed || owner != _identityVersion) throw const ApiFailure('账号已切换');
    if (response['data'] is! Map) throw const ApiFailure('频道响应无效');
    return mapOf(response['data']);
  }

  void _identityChanged() {
    if (_identity == _owner) return;
    _identity = _owner;
    _identityVersion++;
    _drafts.clear();
    unread.clear();
    rewarded = false;
    _reset();
    if (_active) unawaited(_loadReward());
  }

  void select(String id) {
    if (id == channel || !channelIds.contains(id)) return;
    channel = id;
    unread.remove(id);
    _reset();
  }

  void _reset() {
    _epoch++;
    _pollVersion++;
    _stop();
    _cursor = '';
    _snapshot = false;
    messages.clear();
    members = [];
    older = loadingOlder = false;
    feedback = '';
    status = 'connecting';
    notifyListeners();
    if (_active) _connect();
  }

  void activate(bool active) {
    if (_active == active || _closed) return;
    _active = active;
    _stop();
    _pollVersion++;
    if (active) {
      _connect();
      unawaited(_loadReward());
    }
  }

  void _merge(Map<String, dynamic> m) {
    final id = m['id'];
    if (id is! int) return;
    messages[id] = m;
    if (m['removed'] == true) {
      if (draft.replyTo == id) draft.replyTo = null;
      for (final child in messages.values) {
        if (child['replyTo'] == id) child['quote'] = null;
      }
    }
  }

  Future<void> _loadReward() async {
    if (user == null) return;
    final owner = _identityVersion, revision = ++_rewardRevision;
    try {
      final result = await (room.site as SiteDataService).request(
        room.settings.siteUrl,
        'GET',
        '/api/growth/me',
      );
      if (_closed || owner != _identityVersion || revision != _rewardRevision) {
        return;
      }
      final tasks = rowsOf(mapOf(mapOf(result['data'])['today'])['tasks']);
      final complete = tasks.any(
        (r) => r['key'] == 'daily_chatroom' && r['completed'] == true,
      );
      if (rewarded != complete) {
        rewarded = complete;
        notifyListeners();
      }
    } catch (_) {
      /* Reward lookup does not gate channel access. */
    }
  }

  void _stop() {
    _timer?.cancel();
    _probe?.cancel();
    if (_stopStream?.isCompleted == false) _stopStream!.complete();
    _stopStream = null;
    _streaming = false;
  }

  void _connect() {
    final version = _pollVersion;
    unawaited(_poll(version));
    final site = room.site;
    if (site is SiteClient) unawaited(_listen(site, version));
  }

  Future<void> _listen(SiteClient site, int version) async {
    final stop = Completer<void>();
    _stopStream = stop;
    _probe = Timer(const Duration(seconds: 3), () {
      if (!stop.isCompleted && !_streaming) stop.complete();
    });
    try {
      await for (final event in site.channelEvents(
        room.settings.siteUrl,
        channel,
        stop.future,
      )) {
        if (version != _pollVersion || stop.isCompleted) break;
        if (!_streaming && event.data['type'] != 'snapshot') continue;
        _streaming = true;
        _probe?.cancel();
        _timer?.cancel();
        _packet(event.data);
        status = 'live';
        notifyListeners();
      }
    } catch (_) {
      /* A proxy may only support cursor polling. */
    } finally {
      if (!stop.isCompleted) stop.complete();
      if (identical(stop, _stopStream)) _stopStream = null;
      if (version == _pollVersion && _active && _streaming) {
        _streaming = false;
        _cursor = '';
        unawaited(_poll(++_pollVersion));
      }
    }
  }

  void _packet(Map<String, dynamic> p) {
    switch (p['type']) {
      case 'snapshot':
        final batch = rowsOf(p['messages']);
        if (!_snapshot ||
            (batch.isNotEmpty &&
                p['hasOlder'] == true &&
                (messages.lastKey() ?? 0) < batch.first['id'])) {
          // The immediate GET and the stream can overlap a completed send.
          final last = batch.isEmpty ? 0 : batch.last['id'] as int;
          messages.removeWhere((id, _) => id <= last);
          older = p['hasOlder'] == true;
          _snapshot = true;
        }
        batch.forEach(_merge);
      case 'message':
        _merge(mapOf(p['message']));
      case 'presence':
        members = rowsOf(p['members']);
      case 'activity':
        if (p['channel'] is String && p['channel'] != channel) {
          unread.add(p['channel']);
        }
    }
  }

  Future<void> _poll(int version) async {
    var delay = const Duration(milliseconds: 3500);
    try {
      final query = _cursor.isEmpty
          ? ''
          : '?cursor=${Uri.encodeQueryComponent(_cursor)}';
      final data = await _request('$channel/sync$query');
      if (version != _pollVersion || _streaming) return;
      if (data['cursor'] is! String || data['packets'] is! List) {
        throw const ApiFailure('频道响应无效');
      }
      for (final packet in rowsOf(data['packets'])) {
        _packet(packet);
      }
      _cursor = data['cursor'] as String;
      status = 'live';
    } catch (_) {
      if (version != _pollVersion || _streaming) return;
      status = 'reconnecting';
      delay = const Duration(seconds: 3);
    }
    if (version == _pollVersion && _active && !_streaming) {
      notifyListeners();
      _timer = Timer(delay, () => _poll(version));
    }
  }

  Future<void> earlier() async {
    if (!older || loadingOlder || messages.isEmpty) return;
    final epoch = _epoch;
    loadingOlder = true;
    notifyListeners();
    try {
      final data = await _request(
        '$channel/history?before=${messages.firstKey()}',
      );
      if (epoch != _epoch) return;
      for (final m in rowsOf(data['messages'])) {
        if (!messages.containsKey(m['id'])) _merge(m);
      }
      older = data['hasOlder'] == true;
    } catch (error) {
      if (epoch == _epoch) feedback = '$error';
    } finally {
      if (epoch == _epoch) {
        loadingOlder = false;
        notifyListeners();
      }
    }
  }

  void setReply(int? id) {
    draft.replyTo = id;
    notifyListeners();
  }

  Future<void> send() async {
    final entry = draft, content = entry.text.trim(), replyTo = entry.replyTo;
    if (user == null || entry.sending || content.isEmpty) return;
    final id = channel, owner = _identityVersion;
    if (entry.pending?['content'] != content ||
        entry.pending?['replyTo'] != replyTo) {
      entry.pending = {
        'content': content,
        'replyTo': replyTo,
        'requestId': DriftSubmissions.uuid(),
      };
    }
    entry.sending = true;
    feedback = '';
    notifyListeners();
    try {
      final data = await _request('$id/messages', 'POST', entry.pending);
      if (_closed || owner != _identityVersion) return;
      entry.text = '';
      entry.replyTo = null;
      entry.pending = null;
      final award = mapOf(mapOf(data['growth'])['award']);
      if (award['awarded'] == true) {
        _rewardRevision++;
        rewarded = true;
      }
      if (id == channel) _merge(mapOf(data['message']));
    } catch (error) {
      if (!_closed && owner == _identityVersion && id == channel) {
        feedback = '$error';
      }
    } finally {
      entry.sending = false;
      if (!_closed && owner == _identityVersion) notifyListeners();
    }
  }

  Future<Map<String, dynamic>> reports() => _request('reports');

  Future<void> action(int id, String action) async {
    final endpoint = switch (action) {
      'remove' => 'messages/$id',
      'report' || 'dismiss' => 'messages/$id/report',
      'mute' => 'messages/$id/mute',
      _ => throw ArgumentError.value(action),
    };
    if (user == null || ({'dismiss', 'mute'}.contains(action) && !moderator)) {
      return;
    }
    final epoch = _epoch;
    final data = await _request(
      endpoint,
      {'remove', 'dismiss'}.contains(action) ? 'DELETE' : 'POST',
    );
    if (epoch != _epoch) return;
    if (action == 'remove' && data['channel'] == channel) _merge(data);
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _epoch++;
    _pollVersion++;
    _stop();
    room.removeListener(_identityChanged);
    super.dispose();
  }
}
