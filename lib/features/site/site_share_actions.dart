import 'package:flutter/services.dart';

import '../../core/site_repository.dart';

class SiteCopyResult {
  const SiteCopyResult({this.growthRecorded = false});
  final bool growthRecorded;
}

/// Clipboard success is independent of the optional growth side effect.
/// Neither copying anonymously nor an expired session opens a login dialog.
class SiteShareActions {
  SiteShareActions({
    required this.repository,
    required this.canRecordGrowth,
    Future<void> Function(String)? copy,
  }) : _copy = copy ?? _systemCopy;

  final SiteRepository repository;
  final bool Function() canRecordGrowth;
  final Future<void> Function(String) _copy;

  static Future<void> _systemCopy(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  Future<SiteCopyResult> copyLink(
    String value, {
    void Function()? onCopied,
    bool recordGrowth = true,
  }) async {
    final owner = repository.scope;
    final record = recordGrowth && canRecordGrowth();
    await _copy(value);
    if (owner == repository.scope) onCopied?.call();
    if (!record || owner != repository.scope || !canRecordGrowth()) {
      return const SiteCopyResult();
    }
    try {
      await repository.write('POST', '/api/growth/actions/share', {
        'platform': 'copy',
      });
      return const SiteCopyResult(growthRecorded: true);
    } catch (_) {
      // A share mutation is not retried: the response may have been lost after
      // the server awarded growth. The copied link remains usable either way.
      return const SiteCopyResult();
    }
  }
}
