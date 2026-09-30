import '../../core/models.dart';
import '../../core/site_client.dart';

/// Keeps the web site's separate moderator and terminal permissions intact.
class ManagementService {
  ManagementService(this.client, this.site, {required this.terminalSession});
  final SiteDataService client;
  final String site;
  final bool terminalSession;
  String get base => terminalSession ? '/api/admin' : '/api/moderation';
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) {
    if (!terminalSession &&
        method == 'DELETE' &&
        RegExp(r'^/(?:articles|messages)/\d+$').hasMatch(path)) {
      path += '/delete';
      method = 'POST';
    }
    return client.request(site, method, '$base$path', body);
  }

  Future<dynamic> data(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async => (await request(method, path, body))['data'];
  static Map<String, dynamic> approval(
    Map<String, dynamic> message, {
    required bool confirmedExternalLinks,
  }) {
    final moderation = message['moderation'];
    if (moderation is! Map ||
        moderation['reviewDigest'] is! String ||
        (moderation['reviewDigest'] as String).isEmpty) {
      throw const ApiFailure('请重新读取留言后审核');
    }
    if (moderation['blocked'] == true) {
      throw const ApiFailure('留言包含禁止发布的内容');
    }
    final hosts = moderation['externalHosts'];
    if (hosts is List && hosts.isNotEmpty && !confirmedExternalLinks) {
      throw const ApiFailure('请先确认留言中的外部链接');
    }
    return {
      'reviewDigest': moderation['reviewDigest'],
      'confirmExternalLink': confirmedExternalLinks,
    };
  }
}
