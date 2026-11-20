import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/season_theme.dart';
import '../../core/site_localization.dart';
import '../room/room_style.dart';

class HubHero extends StatelessWidget {
  const HubHero({
    super.key,
    required this.input,
    required this.onEnter,
    required this.onDiscover,
  });
  final TextEditingController input;
  final ValueChanged<String> onEnter;
  final VoidCallback onDiscover;
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context), mobile = size.width <= 600;
    final header = size.width <= 860 ? 58.0 : 76.0;
    final season = RoomStyle(context).palette.season;
    final lang = SiteLocaleScope.maybeOf(context)?.language;
    String tr(String zh, String en, String ja) => lang == 'en'
        ? en
        : lang == 'ja'
        ? ja
        : zh;
    final gutter = mobile ? 20.0 : math.max(32.0, size.width * .041);
    final hint = tr('和八千代说点什么…', 'Say something to Yachiyo…', '八千代に話しかけて…');
    return Stack(
      children: [
        Positioned.fill(
          child: Image.asset(
            SeasonalArt(season).hero,
            fit: BoxFit.cover,
            alignment: mobile
                ? const Alignment(.34, -1)
                : const Alignment(0, -.12),
            semanticLabel: tr(
              '月光湖畔的八千代',
              'Yachiyo by the moonlit lake',
              '月明かりの湖畔の八千代',
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: mobile
                  ? const LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Color(0xf50a101b),
                        Color(0xbf0a101b),
                        Color(0x0d0a101b),
                      ],
                      stops: [.03, .38, .75],
                    )
                  : const LinearGradient(
                      colors: [
                        Color(0xd90b0f19),
                        Color(0x910b0f19),
                        Colors.transparent,
                      ],
                      stops: [0, .48, .74],
                    ),
            ),
          ),
        ),
        if (!mobile)
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xc2090e17), Colors.transparent],
                  stops: [0, .48],
                ),
              ),
            ),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: mobile
                ? 780 - header
                : math.max(700, math.min(850, size.height * .94)) - header,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              (mobile ? 280 : 96) - header,
              gutter,
              mobile ? 78 : 55,
            ),
            child: Align(
              alignment: mobile ? Alignment.bottomLeft : Alignment.centerLeft,
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 550),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        tr(
                          '—   留一点月光，给自己',
                          '—   A LITTLE MOONLIGHT, JUST FOR YOU',
                          '—   自分に、少しの月明かりを',
                        ),
                        style: TextStyle(
                          fontSize: mobile ? 10 : 11,
                          letterSpacing: 2,
                        ),
                      ),
                      SizedBox(height: mobile ? 20 : 30),
                      Text(
                        tr(
                          '给日常\n留一点月光。',
                          'A little light,\na little closer.',
                          '日々に、\n月明かりを。',
                        ),
                        style: TextStyle(
                          fontFamily: RoomStyle.serif,
                          fontSize: mobile
                              ? 42
                              : (size.width * .048).clamp(46, 72).toDouble(),
                          height: 1.25,
                          letterSpacing: 3,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: mobile ? 19 : 25),
                      Text(
                        tr(
                          '故事、灵感，还有一直等你的八千代。\n在这里，慢一点也没关系。',
                          'Stories, little discoveries, and Yachiyo waiting for you.\nThere’s no hurry here.',
                          '物語とひらめき、そしてあなたを待つ八千代。\nここでは、ゆっくりでいい。',
                        ),
                        style: TextStyle(
                          height: 1.9,
                          fontSize: mobile ? 14 : 15,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: mobile ? 23 : 30),
                      Container(
                        constraints: const BoxConstraints(maxWidth: 480),
                        padding: const EdgeInsets.fromLTRB(18, 7, 7, 7),
                        decoration: BoxDecoration(
                          color: const Color(0xa30b0f19),
                          borderRadius: BorderRadius.circular(40),
                          border: Border.all(color: Colors.white38),
                        ),
                        child: Row(
                          children: [
                            if (!mobile) ...[
                              const Icon(
                                Icons.chat_bubble_outline,
                                size: 20,
                                color: Colors.white70,
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: TextField(
                                key: const Key('hub-room-draft'),
                                controller: input,
                                maxLength: 2000,
                                textInputAction: TextInputAction.go,
                                onSubmitted: onEnter,
                                style: const TextStyle(color: Colors.white),
                                decoration:
                                    InputDecoration.collapsed(
                                      hintText: hint,
                                      hintStyle: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ).copyWith(
                                      counterText: '',
                                      filled: false,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      border: InputBorder.none,
                                    ),
                              ),
                            ),
                            IconButton.filled(
                              tooltip: tr(
                                '带着这句话进入房间',
                                'Enter the room with your message',
                                'この言葉を持って部屋へ',
                              ),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xff202b46),
                              ),
                              onPressed: () => onEnter(input.text),
                              icon: const Icon(Icons.arrow_forward),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final text in [
                            tr('今天过得怎么样？', 'How was your day?', '今日はどうだった？'),
                            tr('想和你聊聊天', 'I just want to talk', 'お話ししたい'),
                            if (!mobile)
                              tr('给我一点鼓励', 'A little encouragement', '少し励まして'),
                          ])
                            OutlinedButton(
                              onPressed: () => onEnter(text),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white54),
                                backgroundColor: Colors.black26,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                minimumSize: const Size(0, 36),
                                shape: const StadiumBorder(),
                              ),
                              child: Text(
                                '$text  ↗',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: gutter,
          right: gutter,
          bottom: 18,
          child: Row(
            children: [
              if (!mobile)
                Expanded(
                  child: Text(
                    '${lang == 'en' ? season.name.toUpperCase() : ['春日来信', '夏夜晚风', '秋月来信', '冬日灯火'][season.index]}   ──   ${tr('月见八千代', 'TSUKIMI YACHIYO', '月見八千代')}',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              if (mobile) const Spacer(),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: onDiscover,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.transparent,
                    ),
                    child: Text(
                      tr(
                        '向下，发现更多  ﹀',
                        'A little more to discover  ﹀',
                        'もっと見る  ﹀',
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
