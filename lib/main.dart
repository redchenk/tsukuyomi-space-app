import 'features/site/privacy_page.dart';
import 'core/site_localization.dart';
import 'core/desktop_window.dart';

import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import 'core/llm_client.dart';
import 'core/app_theme_controller.dart';
import 'core/site_theme.dart';
import 'core/season_theme.dart';
import 'core/locale_controller.dart';
import 'core/site_client.dart';
import 'core/site_routes.dart';
import 'core/storage.dart';
import 'core/app_update_controller.dart';
import 'core/app_update_release.dart';
import 'core/distribution.dart';
import 'features/updates/app_update_page.dart';
import 'core/voice_service.dart';
import 'features/room/room_controller.dart';
import 'features/room/room_page.dart';
import 'features/room/room_music.dart';
import 'features/room/shared_room_page.dart';
import 'features/site/site_page.dart';
import 'features/site/hub_page.dart';
import 'features/site/site_navigation.dart';
import 'features/settings/settings_page.dart';
import 'features/site/wiki_page.dart';
import 'features/site/reality_page.dart';
import 'features/site/friend_links_page.dart';
import 'features/site/user_profile_page.dart';
import 'features/site/asset_library_page.dart';
import 'features/site/editor_page.dart';
import 'features/site/management_page.dart';
import 'features/site/user_center_page.dart';
import 'features/site/payments_page.dart';
import 'features/pixel/pixel_page.dart';
import 'features/game/game_page.dart';
import 'features/site/native_auth_page.dart';
import 'features/site/site_search.dart';
import 'features/site/site_chrome.dart';
import 'features/site/site_guide.dart';
import 'features/live2d/live2d_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Tsukuyomi site icons (Lucide / Feather)',
    ], await rootBundle.loadString('assets/images/site-icons.LICENSE.txt'));
  });
  final window = await DesktopWindowController.create();
  final preferences = await SharedPreferences.getInstance();
  final controller = RoomController(
    storage: DeviceRoomStorage(preferences),
    chat: LlmClient(),
    site: SiteClient(),
    voice: AudioVoice(),
  );
  runApp(
    TsukuyomiApp(
      controller: controller,
      window: window,
      updates: isGooglePlayBuild
          ? null
          : AppUpdateController(preferences: preferences),
    ),
  );
  await controller.initialize();
}

class TsukuyomiApp extends StatefulWidget {
  const TsukuyomiApp({
    super.key,
    required this.controller,
    this.loadNative = true,
    this.modelLoader,
    this.initialPath = '/room',
    this.updates,
    this.window,
  });
  final RoomController controller;
  final AppUpdateController? updates;
  final DesktopWindowController? window;
  final bool loadNative;
  final Future<Live2DModel> Function()? modelLoader;
  final String initialPath;
  @override
  State<TsukuyomiApp> createState() => _TsukuyomiAppState();
}

class _TsukuyomiAppState extends State<TsukuyomiApp>
    with WidgetsBindingObserver {
  late final AppThemeController _theme;
  late final SeasonThemeController _season;
  late final RoomMusic _music;
  late final LocaleController _locale;
  late final SiteChromeController _chrome;
  late final NavigatorObserver _routeObserver;
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late final ValueNotifier<String> _activePath;
  final _modalOpen = ValueNotifier(false);
  bool get _dark => _theme.dark;
  int _updateNotification = 0;
  AppUpdateRelease? _pendingUpdate;
  Route<dynamic>? _topRoute;
  bool _updatePromptShowing = false, _updatePromptScheduled = false;
  bool _foreground = true;
  final _promptedTags = <String>{};

  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.updates?.addListener(_updateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.updates?.start();
    });
    _music = RoomMusic(widget.controller);
    widget.controller.registerBackgroundMusic(this, _music.suspend);
    _music.load();
    _theme = AppThemeController(widget.controller.storage)
      ..addListener(_themeChanged);
    _theme.restore();
    _season = SeasonThemeController(widget.controller.storage)
      ..addListener(_themeChanged);
    _season.restore();
    _locale = LocaleController(widget.controller.storage)
      ..addListener(_themeChanged);
    _locale.restore();
    _chrome = SiteChromeController(
      widget.controller,
      initialPath: widget.initialPath,
    )..start();
    _chrome.addListener(_scheduleUpdatePrompt);
    _activePath = ValueNotifier(widget.initialPath);
    _routeObserver = _SiteRouteObserver(
      _chrome,
      (path) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _activePath.value != path) _activePath.value = path;
        });
      },
      (route) {
        _topRoute = route;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _modalOpen.value = route is PopupRoute;
        });
        _scheduleUpdatePrompt();
      },
    );
  }

  void _themeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      widget.updates?.checkAutomatically();
      _scheduleUpdatePrompt();
    }
  }

  void _updateChanged() {
    final updates = widget.updates;
    if (!mounted ||
        updates == null ||
        updates.notification == _updateNotification) {
      return;
    }
    _updateNotification = updates.notification;
    _pendingUpdate = updates.release;
    _scheduleUpdatePrompt();
  }

  void _scheduleUpdatePrompt() {
    if (!mounted || _pendingUpdate == null || _updatePromptScheduled) return;
    _updatePromptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updatePromptScheduled = false;
      if (mounted) _showUpdatePrompt();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showUpdatePrompt() async {
    final updates = widget.updates, release = _pendingUpdate;
    final context = _navigator.currentState?.overlay?.context;
    if (updates == null ||
        release == null ||
        context == null ||
        !_foreground ||
        _updatePromptShowing ||
        _chrome.popup != null ||
        _topRoute is! PageRoute ||
        _topRoute?.isCurrent != true) {
      return;
    }
    _pendingUpdate = null;
    if (!updates.automatic ||
        updates.release?.tag != release.tag ||
        updates.preferences.getString('app-update.dismissed') == release.tag) {
      return;
    }
    final path = Uri.tryParse(_topRoute!.settings.name ?? '')?.path;
    if (!_promptedTags.add(release.tag) || path == '/app/update') return;
    // Editors own their save/discard guard. Do not navigate around it.
    final editing = {'/editor', '/room/settings'}.contains(path);
    _updatePromptShowing = true;
    final view = await showDialog<bool>(
      context: context,
      builder: (_) => AppUpdatePrompt(
        release: release,
        currentVersion: updates.installed?.version.value ?? '',
        editing: editing,
      ),
    );
    if (!mounted) return;
    if (view == true) {
      _navigator.currentState?.pushNamed('/app/update');
    } else {
      await updates.remindLater(tag: release.tag);
    }
    _updatePromptShowing = false;
    _scheduleUpdatePrompt();
  }

  void _toggleTheme() {
    _theme.toggle().then((saved) {
      if (!saved && mounted) {
        _messenger.currentState?.showSnackBar(
          const SnackBar(content: SiteText('主题已切换，暂时无法保存到本机')),
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.updates?.removeListener(_updateChanged);
    widget.updates?.dispose();
    widget.controller.unregisterBackgroundMusic(this);
    _music.dispose();
    _theme.removeListener(_themeChanged);
    _theme.dispose();
    _season.removeListener(_themeChanged);
    _season.dispose();
    _locale.removeListener(_themeChanged);
    _locale.dispose();
    _chrome.removeListener(_scheduleUpdatePrompt);
    _chrome.dispose();
    _activePath.dispose();
    _modalOpen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppUpdateScope(
    controller: widget.updates,
    child: SiteSeasonScope(
      controller: _season,
      child: SiteMusicScope(
        music: _music,
        child: SiteControllerScope(
          controller: widget.controller,
          child: SiteLocaleScope(
            controller: _locale,
            child: MaterialApp(
              themeAnimationDuration:
                  WidgetsBinding
                      .instance
                      .platformDispatcher
                      .accessibilityFeatures
                      .disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 650),
              themeAnimationCurve: Curves.easeOutCubic,
              navigatorKey: _navigator,
              navigatorObservers: [_routeObserver],
              locale: _locale.locale,
              supportedLocales: const [
                Locale('zh'),
                Locale('ja'),
                Locale('en'),
              ],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) => DesktopWindowScope(
                controller: widget.window,
                child: DesktopWindowShortcuts(
                  controller: widget.window,
                  child: Shortcuts(
                    shortcuts: const {
                      SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                          _SearchIntent(),
                      SingleActivator(LogicalKeyboardKey.keyK, control: true):
                          _SearchIntent(),
                    },
                    child: Actions(
                      actions: {
                        _SearchIntent: CallbackAction<_SearchIntent>(
                          onInvoke: (_) {
                            final route = Uri.tryParse(_activePath.value)?.path;
                            if ([
                              '/',
                              '/login',
                              '/register',
                              '/live2d',
                            ].contains(route)) {
                              return null;
                            }
                            final navigatorContext =
                                _navigator.currentState?.overlay?.context;
                            if (navigatorContext != null) {
                              showSiteSearch(
                                navigatorContext,
                                widget.controller,
                                (path) => navigateSite(
                                  navigatorContext,
                                  widget.controller,
                                  path,
                                ),
                              );
                            }
                            return null;
                          },
                        ),
                      },
                      child: SiteChromeScope(
                        controller: _chrome,
                        child: Overlay.wrap(
                          child: SiteVisitPopupOverlay(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                child ?? const SizedBox(),
                                Positioned(
                                  right: 14,
                                  bottom: 12,
                                  child: ListenableBuilder(
                                    listenable: Listenable.merge([
                                      _activePath,
                                      _modalOpen,
                                    ]),
                                    builder: (context, _) {
                                      final path = _activePath.value;
                                      final route =
                                          Uri.tryParse(path)?.path ?? '/';
                                      final hidden =
                                          [
                                            '/',
                                            '/login',
                                            '/register',
                                            '/room',
                                            '/room/settings',
                                            '/game',
                                          ].contains(route) ||
                                          route.startsWith('/room/shared/') ||
                                          _modalOpen.value;
                                      return Offstage(
                                        offstage: hidden,
                                        child: TickerMode(
                                          enabled: !hidden,
                                          child: SiteGuideButton(
                                            controller: widget.controller,
                                            path: path,
                                            width:
                                                MediaQuery.sizeOf(context)
                                                        .width <=
                                                    860
                                                ? 56
                                                : 110,
                                            reduced:
                                                hidden || !widget.loadNative,
                                            dialogContext: () => _navigator
                                                .currentState!
                                                .overlay!
                                                .context,
                                            onGo: (next) => navigateSite(
                                              _navigator
                                                  .currentState!
                                                  .overlay!
                                                  .context,
                                              widget.controller,
                                              next,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              title: '月读空间',
              debugShowCheckedModeBanner: false,
              scaffoldMessengerKey: _messenger,
              theme: siteTheme(_dark, season: _season.season),
              initialRoute: widget.initialPath,
              onGenerateRoute: _route,
              onGenerateInitialRoutes: (name) => [
                _route(RouteSettings(name: name)),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  MaterialPageRoute<void> _route(RouteSettings settings) {
    final requested = settings.name ?? '';
    final path = nativeSitePath(Uri.parse(requested));
    return MaterialPageRoute<void>(
      settings: RouteSettings(
        name: path ?? requested,
        arguments: settings.arguments,
      ),
      builder: (context) {
        final route = path == null ? null : Uri.parse(path).path;
        void go(String value) =>
            navigateSite(context, widget.controller, value);
        final c = widget.controller;
        if (route == '/app/update' && widget.updates != null) {
          return AppUpdatePage(
            updates: widget.updates!,
            room: c,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/live2d') {
          return Live2DPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
            loadNative: widget.loadNative,
            modelLoader: widget.modelLoader,
          );
        }
        if (route == '/login' || route == '/register') {
          return NativeAuthPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/game') {
          return GamePage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/wiki' || route?.startsWith('/wiki/') == true) {
          return WikiPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/privacy' || route == '/delete-account') {
          return PrivacyPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/reality') {
          return RealityPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/friend-links' || route == '/friend-links/apply') {
          return FriendLinksPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route?.startsWith('/users/') == true) {
          return UserProfilePage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/gallery' || route == '/gallery/manage') {
          return GalleryPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/attachments') {
          return AttachmentsPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/editor') {
          return EditorPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/pixel') {
          return PixelPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/user') {
          return UserCenterPage(controller: c, onGo: go, onTheme: _toggleTheme);
        }
        if (route == '/payments') {
          return PaymentsPage(
            controller: c,
            onGo: go,
            onTheme: _toggleTheme,
            orderId: Uri.parse(path!).queryParameters['order'],
          );
        }
        if (route == '/admin' || route == '/terminal') {
          return ManagementPage(
            controller: c,
            path: path!,
            onGo: go,
            onTheme: _toggleTheme,
          );
        }
        if (route == '/room/settings') {
          final section = Uri.parse(path!).queryParameters['section'];
          return RoomSettingsPage(
            controller: widget.controller,
            guidedSetup: Uri.parse(path).queryParameters['setup'] == '1',
            initialSection: roomSections.containsKey(section)
                ? section!
                : 'llm',
            onTheme: _toggleTheme,
          );
        }
        if (route == '/hub') {
          return HubPage(
            controller: widget.controller,
            onGo: (value) =>
                navigateSite(context, widget.controller, value, replace: true),
            onTheme: _toggleTheme,
          );
        }
        if (route == '/room') return _room(context);
        if (route?.startsWith('/room/shared/') == true) {
          return SharedRoomPage(
            controller: c,
            shareKey: Uri.parse(path!).pathSegments[2],
            onGo: go,
            onTheme: _toggleTheme,
            loadNative: widget.loadNative,
            modelLoader: widget.modelLoader,
          );
        }
        if (path == null) {
          return SiteRouteFallback(
            controller: widget.controller,
            path: requested,
          );
        }
        return SitePage(
          controller: widget.controller,
          path: path,
          onTheme: _toggleTheme,
        );
      },
    );
  }

  Widget _room(BuildContext context) => RoomPage(
    controller: widget.controller,
    onNavigate: (path) => navigateSite(context, widget.controller, path),
    loadNative: widget.loadNative,
    modelLoader: widget.modelLoader,
    onToggleTheme: _toggleTheme,
  );
}

class _SearchIntent extends Intent {
  const _SearchIntent();
}

class _SiteRouteObserver extends NavigatorObserver {
  _SiteRouteObserver(this.chrome, this.onPath, this.onRoute);
  final SiteChromeController chrome;
  final ValueChanged<String> onPath;
  final ValueChanged<Route<dynamic>?> onRoute;
  void _changed(Route<dynamic>? route) {
    onRoute(route);
    if (route is PageRoute) {
      final path = route.settings.name ?? '/';
      chrome.routeChanged(path);
      onPath(path);
    }
  }

  // Also covers removeRoute when an open menu loses its account permissions.
  @override
  void didChangeTop(
    Route<dynamic> topRoute,
    Route<dynamic>? previousTopRoute,
  ) => _changed(topRoute);
}
