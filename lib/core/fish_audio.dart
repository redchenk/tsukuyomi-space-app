import 'models.dart';

/// Fish request contract shared with the website's shared/fish-audio.cjs.
class FishAudio {
  static const endpoint = 'https://api.fish.audio/v1/tts';
  static const voice = 'a746d80afdb5451ca44c63401c001c9b';
  static const models = [
    's2.1-pro',
    'drama-3',
    's2-pro',
    's2.1-pro-free',
    's1',
  ];
  static const styles = {
    'happy': '开心',
    'calm': '平静',
    'excited': '兴奋',
    'sad': '难过',
    'angry': '生气',
    'surprised': '惊讶',
    'embarrassed': '害羞',
    'proud': '得意',
    'curious': '好奇',
    'empathetic': '体贴',
    'whispering': '轻声',
  };
  static const expressions = {
    'closed_smile': 'happy',
    'closed_eyes': 'calm',
    'shy': 'embarrassed',
    'smug': 'proud',
    'fire': 'excited',
    'tear_drop': 'sad',
    'watery_eyes': 'sad',
    'crying': 'sad',
    'puff': 'angry',
    'tongue': 'happy',
    'dizzy': 'surprised',
  };
  static String emotion(RoomSettings settings) {
    final style = settings.option('fishStyle', 'auto');
    final emotion = settings.option('replyEmotion');
    return style == 'auto'
        ? (styles.containsKey(emotion) ? emotion : expressions[emotion] ?? '')
        : styles.containsKey(style)
        ? style
        : '';
  }

  static void validate(RoomSettings settings) {
    if (!models.contains(settings.ttsModel)) {
      throw const ApiFailure('请选择支持情感提示的 Fish Audio 模型');
    }
    if (settings.voice.isNotEmpty &&
        !RegExp(
          r'^[0-9a-f]{32}$',
          caseSensitive: false,
        ).hasMatch(settings.voice)) {
      throw const ApiFailure('Fish Audio 音色 ID 应为 32 位十六进制字符');
    }
    if (settings.ttsKey.trim().isEmpty) {
      throw const ApiFailure('请填写 Fish Audio API 密钥');
    }
    if (settings.ttsUrl != endpoint) {
      throw const ApiFailure('Fish Audio 请使用官方接口地址');
    }
  }

  static Map<String, dynamic> body(RoomSettings settings, String text) {
    validate(settings);
    final style = emotion(settings);
    final cue = style.isEmpty
        ? ''
        : settings.ttsModel == 's1'
        ? '($style) '
        : '[$style] ';
    return {
      'text': '$cue$text',
      if (settings.voice.isNotEmpty) 'reference_id': settings.voice,
      'format': 'mp3',
    };
  }
}
