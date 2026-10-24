import 'model_runtime.dart';
import 'models.dart';

/// Money uses the site's integer billionths of a yuan, including on the web.
String moneyAtoms(dynamic value) {
  final amount = BigInt.tryParse('${value ?? 0}');
  if (amount == null) throw const ApiFailure('金额数据无效，请刷新重试');
  final scale = BigInt.from(1000000000), absolute = amount.abs();
  var fraction = (absolute % scale)
      .toString()
      .padLeft(9, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  fraction = fraction.padRight(2, '0');
  return '${amount.isNegative ? '-' : ''}${absolute ~/ scale}.$fraction';
}

String rateAtoms(String value) {
  if (!RegExp(r'^(0|[1-9][0-9]{0,5})(\.[0-9]{1,9})?$').hasMatch(value)) {
    throw const ApiFailure('单价最多支持 9 位小数');
  }
  final parts = value.split('.');
  return (BigInt.parse(parts.first) * BigInt.from(1000000000) +
          BigInt.parse((parts.length == 2 ? parts.last : '').padRight(9, '0')))
      .toString();
}

Map<String, dynamic> officialDashboard(
  Map<String, dynamic> data,
  String siteUserId,
) {
  final me = data['me'];
  if (siteUserId.isEmpty ||
      me is! Map ||
      me['site_user_id'] != siteUserId ||
      me['account_id'] is! String ||
      (me['account_id'] as String).isEmpty ||
      data['models'] is! List) {
    throw const ApiFailure('登录账号已变化，请刷新支付中心后重试', status: 409);
  }
  return data;
}

bool officialModelSupportsImages(Map model) =>
    model['capabilities'] is Map &&
    (model['capabilities'] as Map)['vision'] == true;

RoomSettings officialRoomSettings(
  RoomSettings settings,
  Map<String, dynamic> dashboard,
) {
  if (dashboard['enabled'] != true) throw const ApiFailure('站内直供暂未开放，请稍后再试');
  final models = (dashboard['models'] as List).whereType<Map>().where(
    (m) =>
        m['id'] == settings.model &&
        m['enabled'] == true &&
        m['max_output_tokens'] is int &&
        m['max_output_tokens'] >= 16,
  );
  if (models.isEmpty) throw const ApiFailure('该站内模型暂不可用，请刷新模型列表');
  final model = models.first;
  final vision = officialModelSupportsImages(model);
  final next = settings.copyWith(
    llmUrl: endpointUri(settings.siteUrl)
        .resolve('/official-api/v1/chat/completions')
        .toString(),
    apiKey: '',
    demo: false,
    options: {
      ...settings.options,
      'llmProxy': false,
      'llmConnection': 'site',
      'officialProvider': model['provider'],
    },
  );
  final runtime = ModelRuntime(next),
      config = normalizeModelRuntime(next.options['runtimeConfig']);
  final layer = Map<String, dynamic>.from(
    (config['models'] as Map)[runtime.modelKey] as Map? ?? {},
  );
  final requested = runtime.resolveParameters()['maxOutputTokens']['value'];
  (config['models'] as Map)[runtime.modelKey] = {
    ...layer,
    'parameters': {
      ...?layer['parameters'] as Map?,
      'maxOutputTokens':
          requested is num && requested < model['max_output_tokens']
          ? requested
          : model['max_output_tokens'],
    },
    'mappings': {
      ...?layer['mappings'] as Map?,
      'maxOutputTokens': 'max_tokens',
    },
    'capabilities': {
      'text': true,
      'image': vision,
      'tools': true,
      'streaming': true,
    },
  };
  (config['declarations'] as Map)[runtime.modelKey] = {
    'text': true,
    'image': vision,
    'tools': true,
    'streaming': true,
  };
  return next.copyWith(options: {...next.options, 'runtimeConfig': config});
}

String usageStatus(dynamic status) => switch (status) {
  'reserved' => '处理中',
  'settled' => '已结算',
  'released' => '未消费，已释放',
  'unknown' => '待核对',
  'needs_review' => '待人工核对',
  _ => '待核对',
};
