import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/site_routes.dart';

void main() {
  test('native routes retain aliases, queries, slugs and fragments', () {
    final routes = {
      '/hub': '/hub',
      '/': '/',
      '/access': '/',
      '/wiki': '/wiki',
      '/wiki/characters/yachiyo': '/wiki/characters/yachiyo',
      '/wiki/terms/tsukuyomi#source': '/wiki/terms/tsukuyomi#source',
      '/gallery/manage': '/gallery/manage',
      '/users/alice': '/users/alice',
      '/room/shared/share_01': '/room/shared/share_01',
      '/arena/legacy?q=one#art': '/pixel?q=one#art',
      '/room/': '/room',
      '/room-settings?section=memory': '/room/settings?section=memory',
      '/user-center?tab=articles': '/user?tab=articles',
      '/article?id=42&from=%2Fstage#comments':
          '/articles/42?from=%2Fstage#comments',
      '/articles/42/moon?q=%E6%9C%88#comments':
          '/articles/42/moon?q=%E6%9C%88#comments',
      '/articles/a%20b': '/articles/a%20b',
      '/plaza?page=2#message-3': '/plaza?page=2#message-3',
    };
    for (final entry in routes.entries) {
      expect(
        nativeSitePath(Uri.parse(entry.key)),
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('only actual native pages resolve to native destinations', () {
    for (final path in [
      '/wiki/unknown/entry',
      '/users/a%2Fb',
      '/room/shared/a%2Fb',
      '/unknown',
      '/article',
      '/articles/',
      '/articles/42/a/b',
      '/articles/a%2Fb',
    ]) {
      expect(nativeSitePath(Uri.parse(path)), isNull, reason: path);
    }
    expect(nativeSitePath(Uri.parse('https://yachiyo.hk/hub')), isNull);
  });

  test(
    'same-origin absolute links enter native routes without losing parameters',
    () {
      final target = resolveSiteTarget(
        'https://yachiyo.hk',
        'https://yachiyo.hk/article?id=42#comments',
      );
      expect(target.nativePath, '/articles/42#comments');
      expect(
        resolveSiteTarget('https://yachiyo.hk', '/hub').nativePath,
        '/hub',
      );
      expect(
        resolveSiteTarget('https://yachiyo.hk', '/wiki').nativePath,
        '/wiki',
      );
      expect(
        resolveSiteTarget(
          'https://yachiyo.hk',
          'https://example.org/hub',
        ).nativePath,
        isNull,
      );
      expect(
        resolveSiteTarget(
          'https://yachiyo.hk',
          'https://yachiyo.hk:443/hub',
        ).nativePath,
        '/hub',
      );
      expect(
        resolveSiteTarget(
          'http://127.0.0.1:4184',
          'http://127.0.0.1:4185/hub',
        ).nativePath,
        isNull,
      );
    },
  );

  test('unsupported protocols and credential URLs cannot be launched', () {
    for (final value in [
      'javascript:alert(1)',
      'file:///etc/passwd',
      'https://name:password@yachiyo.hk/hub',
    ]) {
      expect(
        () => resolveSiteTarget('https://yachiyo.hk', value),
        throwsFormatException,
      );
    }
  });
}
