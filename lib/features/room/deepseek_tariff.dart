import 'package:flutter/material.dart';

import '../../core/official_api.dart';

/// Show only the server-published rational rates; never infer a provider price.
class DeepseekTariff extends StatelessWidget {
  const DeepseekTariff({super.key, required this.model});
  final Map<String, dynamic> model;
  String rate(String name, [int count = 1]) {
    final raw = model['tools_price']?['rates']?[name];
    final numerator = BigInt.tryParse('${raw?['numerator']}'),
        denominator = BigInt.tryParse('${raw?['denominator']}');
    if (numerator == null || denominator == null || denominator <= BigInt.zero) {
      return '—';
    }
    return moneyAtoms(
      (numerator * BigInt.from(count) ~/ denominator).toString(),
    );
  }

  @override
  Widget build(BuildContext context) => model['tools_price'] is! Map
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '搜索与阅读链接 ¥${rate('search')}/次 · OCR 与文件解析 ¥${rate('ocr_pages')}/页 · 语音识别 ¥${rate('asr_seconds', 3600)}/小时。\n'
            '聊天请求预留 ¥${moneyAtoms(model['reservation_atoms'])}；按实际用量结算并释放余款。多步思考按整轮累计计费，用量不完整时转入待核对。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
}
