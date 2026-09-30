import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import 'native_article_document.dart' show nativeArticleUrl;
import 'site_notification.dart';
import 'site_widgets.dart' show openSiteLink;

String visitPopupSignature(Map<String, dynamic> settings) =>
    Uri.encodeComponent(
      [
        '${settings['visitPopupTitle'] ?? ''}',
        '${settings['visitPopupContent'] ?? ''}',
        '${settings['visitPopupButton'] ?? ''}',
      ].join('\n'),
    );

class NativeVisitPopup {
  const NativeVisitPopup(this.title, this.content, this.button, this.signature);
  final String title, content, button, signature;
}

class SiteBeian {
  const SiteBeian({
    this.text = '',
    this.url = '',
    this.mpsText = '',
    this.mpsUrl = '',
    this.mpsIcon = '',
  });
  factory SiteBeian.from(Map values) {
    String first(List<String> keys) {
      for (final key in keys) {
        final value = '${values[key] ?? ''}'.trim();
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    return SiteBeian(
      text: first(['beianText', 'text']),
      url: first(['beianUrl', 'url']),
      mpsText: first(['mpsBeianText', 'publicSecurityBeianText', 'mpsText']),
      mpsUrl: first(['mpsBeianUrl', 'publicSecurityBeianUrl', 'mpsUrl']),
      mpsIcon: first(['mpsBeianIcon', 'publicSecurityBeianIcon', 'mpsIcon']),
    );
  }
  final String text, url, mpsText, mpsUrl, mpsIcon;
  Map<String, String> toJson() => {
    'text': text,
    'url': url,
    'mpsText': mpsText,
    'mpsUrl': mpsUrl,
    'mpsIcon': mpsIcon,
  };
}

/// Public chrome settings and account-specific notification counts have separate
/// lifetimes. Notification counts are never written to disk or public caches.
class SiteChromeController extends ChangeNotifier with WidgetsBindingObserver {
  SiteChromeController(
    this.room, {
    this.hideDomesticRegistration = false,
    String initialPath = '/',
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    _owner = owner;
    _origin = origin;
    _viewPath = initialPath;
    _waitingForInitialization = room.loading;
    room.addListener(_accountChanged);
    WidgetsBinding.instance.addObserver(this);
    _visible =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }
  static const unreadPollInterval = Duration(seconds: 60);
  final RoomController room;
  final bool hideDomesticRegistration;
  final DateTime Function() now;
  String _owner = '', _origin = '', _route = '';
  String _viewPath = '/';
  bool _waitingForInitialization = true;
  bool _disposed = false,
      _visible = true,
      _pendingVisit = false,
      _started = false;
  int unread = 0, _unreadRequest = 0, _settingsRevision = 0, _routeRevision = 0;
  NativeVisitPopup? popup;
  SiteBeian beian = const SiteBeian();
  Timer? _poll;
  Future<void>? _unreadFuture;
  Future<Map<String, dynamic>>? _settingsFuture;
  Map<String, dynamic>? _settings;
  Map<String, dynamic> publicStats = {};
  final _viewRequests = <String, Future<Map<String, dynamic>?>>{};
  final _viewMarkerWrites = <String, Future<void>>{};
  final _recordedViews = <String, String>{};
  DateTime? _settingsAt;
  String get origin => endpointUri(room.settings.siteUrl).origin;
  String get owner =>
      '$origin:${room.account?.id ?? 'guest'}:${room.sessionExpired}:${room.site.cookie ?? ''}';
  bool get authed => room.account != null && !room.sessionExpired;
  bool get visible => _visible;
  bool get pendingVisit => _pendingVisit;
  SiteDataService? get api =>
      room.site is SiteDataService ? room.site as SiteDataService : null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_disposed || _started) return;
    _started = true;
    unawaited(loadBeian());
    _restartPolling();
    unawaited(refreshUnread());
    unawaited(recordDailyView());
  }

  void _accountChanged() {
    if (_disposed) return;
    final becameReady = _waitingForInitialization && !room.loading;
    _waitingForInitialization = room.loading;
    if (_owner == owner) {
      if (_started && becameReady) unawaited(recordDailyView());
      return;
    }
    final nextOrigin = origin;
    _owner = owner;
    _unreadRequest++;
    _unreadFuture = null;
    unread = 0;
    if (_origin != nextOrigin) {
      _origin = nextOrigin;
      _settingsRevision++;
      _routeRevision++;
      _settingsFuture = null;
      _settings = null;
      _settingsAt = null;
      popup = null;
      beian = const SiteBeian();
      publicStats = {};
      _pendingVisit = false;
      if (_started) unawaited(loadBeian());
    }
    _notify();
    if (_started) {
      _restartPolling();
      unawaited(refreshUnread());
      unawaited(recordDailyView());
    }
  }

  void _restartPolling() {
    _poll?.cancel();
    _poll = null;
    if (_started && authed && _visible) {
      _poll = Timer.periodic(unreadPollInterval, (_) => refreshUnread());
    }
  }

  void setVisible(bool visible) {
    if (_disposed || _visible == visible) return;
    _visible = visible;
    _restartPolling();
    if (visible && _started) {
      unawaited(refreshUnread());
      unawaited(recordDailyView());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      setVisible(state == AppLifecycleState.resumed);

  static String viewStorageKey(String origin) =>
      'tsukuyomi_site_view_recorded:$origin';

  /// Same YYYY-MM-DD and account namespace as App.vue in Asia/Hong_Kong.
  String get dailyViewMarker {
    final day = now().toUtc().add(const Duration(hours: 8));
    final date =
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    final user = room.account;
    final identity = authed && user != null
        ? '${user.scope == 'admin' ? 'admin' : 'user'}:${user.id}'
        : 'visitor';
    return '$date:$identity';
  }

  /// Failures leave the marker untouched. A later navigation, identity change or
  /// visible resume retries; no periodic background visit writes are scheduled.
  Future<Map<String, dynamic>?> recordDailyView() {
    if (_disposed || !_visible || room.loading || room.busy || api == null) {
      return Future.value(null);
    }
    final current = origin, marker = dailyViewMarker;
    if (_recordedViews[current] == marker) return Future.value(null);
    final key = '$current:$marker';
    if (_viewRequests.containsKey(key)) return _viewRequests[key]!;
    final completion = Completer<Map<String, dynamic>?>();
    _viewRequests[key] = completion.future;
    unawaited(
      _recordDailyView(
        current,
        marker,
        _viewPath,
      ).then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  bool _currentView(String current, String marker) =>
      !_disposed && current == origin && marker == dailyViewMarker;

  Future<Map<String, dynamic>?> _recordDailyView(
    String current,
    String marker,
    String path,
  ) async {
    final requestKey = '$current:$marker';
    try {
      final seen = await room.storage.draft(viewStorageKey(current));
      if (!_currentView(current, marker) || room.loading || room.busy) {
        return null;
      }
      if (seen == marker) {
        _recordedViews[current] = marker;
        return null;
      }
      final result = await api!.request(current, 'POST', '/api/stats/view', {
        'path': path.isEmpty ? '/' : path,
      });
      if (result['success'] != true || !_currentView(current, marker)) {
        return null;
      }
      final previous = _viewMarkerWrites[current] ?? Future<void>.value();
      final write = previous.catchError((_) {}).then((_) async {
        if (!_currentView(current, marker)) return;
        await room.storage.saveDraft(viewStorageKey(current), marker);
      });
      _viewMarkerWrites[current] = write;
      await write;
      if (!_currentView(current, marker)) return result;
      _recordedViews[current] = marker;
      if (result['data'] is Map) {
        publicStats = Map<String, dynamic>.from(result['data'] as Map);
        _notify();
      }
      return result;
    } catch (_) {
      return null;
    } finally {
      _viewRequests.remove(requestKey);
    }
  }

  Future<void> refreshUnread() {
    if (_disposed || !_visible || api == null) return Future<void>.value();
    if (!authed) {
      publishUnread(0);
      return Future<void>.value();
    }
    if (_unreadFuture != null) return _unreadFuture!;
    final current = owner, ticket = ++_unreadRequest;
    // Publish the pending marker before starting the request. A custom site
    // transport may complete inline, including its finally cleanup.
    final completion = Completer<void>();
    _unreadFuture = completion.future;
    unawaited(
      _readUnread(
        current,
        ticket,
      ).then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  Future<void> _readUnread(String current, int ticket) async {
    try {
      final response = await api!.request(
        room.settings.siteUrl,
        'GET',
        '/api/user/notifications/unread-count',
      );
      if (!_disposed &&
          current == owner &&
          ticket == _unreadRequest &&
          authed) {
        final data = response['data'];
        if (response['success'] == true) {
          unread = notificationUnreadCount(
            data is Map ? data['count'] : 0,
            const [],
          );
        }
        _notify();
      }
    } catch (e) {
      if (!_disposed &&
          current == owner &&
          ticket == _unreadRequest &&
          e is ApiFailure &&
          e.status == 401) {
        unread = 0;
        _notify();
        room.expireSession();
      }
    } finally {
      if (ticket == _unreadRequest) _unreadFuture = null;
    }
  }

  /// A successful read/read-all immediately updates every bell and invalidates
  /// any count request that began before the mutation.
  void publishUnread(int count, {String? forOwner}) {
    if (_disposed || (forOwner != null && forOwner != owner)) return;
    _unreadRequest++;
    _unreadFuture = null;
    final value = authed ? count.clamp(0, 0x7fffffff) : 0;
    if (unread != value) {
      unread = value;
      _notify();
    }
  }

  Future<Map<String, dynamic>> publicSettings({bool force = false}) {
    if (_disposed || api == null) return Future.value({});
    if (!force &&
        _settings != null &&
        _settingsAt != null &&
        now().difference(_settingsAt!) < const Duration(seconds: 30)) {
      return Future.value(Map.of(_settings!));
    }
    if (_settingsFuture != null) return _settingsFuture!;
    final current = origin, ticket = ++_settingsRevision;
    final completion = Completer<Map<String, dynamic>>();
    _settingsFuture = completion.future;
    unawaited(
      _readSettings(
        current,
        ticket,
      ).then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  Future<Map<String, dynamic>> _readSettings(String current, int ticket) async {
    try {
      final response = await api!.request(
        room.settings.siteUrl,
        'GET',
        '/api/settings',
      );
      if (_disposed || current != origin || ticket != _settingsRevision) {
        return {};
      }
      if (response['success'] != true) throw const ApiFailure('站点设置暂时无法读取');
      final data = response['data'];
      _settings = data is Map ? Map<String, dynamic>.from(data) : {};
      _settingsAt = now();
      return Map.of(_settings!);
    } finally {
      if (ticket == _settingsRevision) _settingsFuture = null;
    }
  }

  Future<void> loadBeian() async {
    if (hideDomesticRegistration || _disposed) return;
    final current = origin, key = 'tsukuyomi_beian_public_settings:$origin';
    try {
      final cached = await room.storage.draft(key);
      if (!_disposed && current == origin && cached.isNotEmpty) {
        beian = SiteBeian.from(jsonDecode(cached) as Map);
        _notify();
      }
    } catch (_) {}
    try {
      final settings = await publicSettings();
      if (_disposed || current != origin) return;
      beian = SiteBeian.from(settings);
      _notify();
      try {
        await room.storage.saveDraft(
          key,
          beian.text.isNotEmpty || beian.mpsText.isNotEmpty
              ? jsonEncode(beian.toJson())
              : '',
        );
      } catch (_) {}
    } catch (_) {
      /* Keep a previously validated public setting while offline. */
    }
  }

  Future<void> routeChanged(String path) async {
    if (_disposed) return;
    final previousFullPath = _viewPath;
    _viewPath = path;
    if (_started && previousFullPath != path) unawaited(recordDailyView());
    final next = Uri.tryParse(path)?.path ?? path, previous = _route;
    if (next == previous) return;
    _route = next;
    if (['/', '/access', '/access.html'].contains(previous) && next == '/hub') {
      _pendingVisit = true;
    }
    final ticket = ++_routeRevision, current = origin;
    unawaited(refreshUnread());
    if (next != '/hub' || !_pendingVisit) return;
    _pendingVisit = false;
    try {
      final settings = await publicSettings();
      if (_disposed || ticket != _routeRevision || current != origin) return;
      final title = '${settings['visitPopupTitle'] ?? ''}'.trim(),
          content = '${settings['visitPopupContent'] ?? ''}'.trim();
      if (settings['visitPopupEnabled'] != true ||
          (title.isEmpty && content.isEmpty)) {
        return;
      }
      final signature = visitPopupSignature(settings),
          seen = await room.storage.draft(
            'tsukuyomi_visit_popup_seen:$current',
          );
      if (_disposed ||
          ticket != _routeRevision ||
          current != origin ||
          seen == signature) {
        return;
      }
      final button = '${settings['visitPopupButton'] ?? ''}'.trim();
      popup = NativeVisitPopup(
        title.isEmpty ? '月读空间' : title,
        content,
        button.isEmpty ? '我知道了' : button,
        signature,
      );
      _notify();
    } catch (_) {
      /* Pending is consumed once, just like sessionStorage on the site. */
    }
  }

  Future<void> closeVisitPopup() async {
    final current = popup;
    if (_disposed || current == null) return;
    final site = origin;
    popup = null;
    _notify();
    try {
      await room.storage.saveDraft(
        'tsukuyomi_visit_popup_seen:$site',
        current.signature,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _unreadRequest++;
    _settingsRevision++;
    _routeRevision++;
    room.removeListener(_accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class SiteChromeScope extends InheritedNotifier<SiteChromeController> {
  const SiteChromeScope({
    super.key,
    required SiteChromeController controller,
    required super.child,
  }) : super(notifier: controller);
  static SiteChromeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SiteChromeScope>()?.notifier;
}

void publishSiteUnread(BuildContext context, int count, {String? forOwner}) =>
    SiteChromeScope.maybeOf(context)?.publishUnread(count, forOwner: forOwner);

class SiteNotificationBadge extends StatelessWidget {
  const SiteNotificationBadge({super.key, this.size = 20});
  final double size;
  @override
  Widget build(BuildContext context) {
    final count = SiteChromeScope.maybeOf(context)?.unread ?? 0;
    return Badge(
      isLabelVisible: count > 0,
      backgroundColor: const Color(0xffcf8295),
      child: Icon(Icons.notifications_none, size: size),
    );
  }
}

class SiteVisitPopupOverlay extends StatelessWidget {
  const SiteVisitPopupOverlay({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final controller = SiteChromeScope.maybeOf(context),
        popup = controller?.popup;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        if (popup != null)
          Positioned.fill(
            child: BlockSemantics(
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: ModalBarrier(
                      dismissible: false,
                      color: Colors.black54,
                    ),
                  ),
                  Center(
                    child: Semantics(
                      scopesRoute: true,
                      explicitChildNodes: true,
                      namesRoute: true,
                      label: popup.title,
                      child: Dialog(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: 520,
                            maxHeight: MediaQuery.sizeOf(context).height * .85,
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  popup.title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall,
                                ),
                                const SizedBox(height: 16),
                                Text(popup.content),
                                const SizedBox(height: 24),
                                FilledButton(
                                  onPressed: controller!.closeVisitPopup,
                                  child: Text(popup.button),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class SiteBeianLinks extends StatelessWidget {
  const SiteBeianLinks({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = SiteChromeScope.maybeOf(context);
    if (controller == null || controller.hideDomesticRegistration) {
      return const SizedBox();
    }
    final beian = controller.beian;
    Widget link(String label, String value, {bool mps = false}) {
      final safe = nativeArticleUrl(value),
          fallback = mps
              ? 'https://beian.mps.gov.cn/'
              : 'https://beian.miit.gov.cn/';
      return TextButton(
        onPressed: () => openSiteLink(
          controller.room.settings.siteUrl,
          safe.isEmpty ? fallback : safe,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mps)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: Image.network(
                    endpointUri(controller.room.settings.siteUrl)
                        .resolve(
                          nativeArticleUrl(beian.mpsIcon).isEmpty
                              ? '/assets/images/beian-mps.png'
                              : nativeArticleUrl(beian.mpsIcon),
                        )
                        .toString(),
                    errorBuilder: (_, _, _) => const SizedBox(),
                  ),
                ),
              ),
            Flexible(child: Text(label, textAlign: TextAlign.center)),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (beian.text.isNotEmpty) link(beian.text, beian.url),
        if (beian.mpsText.isNotEmpty)
          link(beian.mpsText, beian.mpsUrl, mps: true),
      ],
    );
  }
}

/// AppShell's footer is hidden on immersive pages, Hub and all room routes.
bool siteShowsBeian(String path) {
  final page = Uri.tryParse(path)?.path ?? path;
  return ![
        '/',
        '/access',
        '/access.html',
        '/login',
        '/register',
        '/live2d',
        '/hub',
        '/room',
        '/room-settings',
        '/settings',
      ].contains(page) &&
      !page.startsWith('/room/');
}

/// Common footer for native page shells. Empty/unavailable settings occupy no
/// space; the configured registration identifiers stay literal in every locale.
class SiteBeianFooter extends StatelessWidget {
  const SiteBeianFooter({super.key, this.path});
  final String? path;
  @override
  Widget build(BuildContext context) {
    final controller = SiteChromeScope.maybeOf(context);
    if (controller == null ||
        controller.hideDomesticRegistration ||
        !siteShowsBeian(path ?? ModalRoute.of(context)?.settings.name ?? '') ||
        (controller.beian.text.isEmpty && controller.beian.mpsText.isEmpty)) {
      return const SizedBox.shrink();
    }
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: SiteBeianLinks(),
    );
  }
}
