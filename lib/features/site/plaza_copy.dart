import 'package:flutter/widgets.dart';

import '../../core/site_localization.dart';

// Current PlazaPage / PlazaComposer copy, kept separate from user-authored text.
String plazaCopy(BuildContext context, String source) {
  final language = SiteLocaleScope.maybeOf(context)?.language ?? 'zh';
  final copy = _copy[source];
  return copy == null || language == 'zh'
      ? siteTranslate(context, source)
      : copy[language == 'ja' ? 0 : 1];
}

const _copy = <String, List<String>>{
  '留下一句问候，分享一点灵感。在这里，遇见同频的朋友。': [
    '挨拶も、ひらめきも。ここで同じ気持ちの仲間に出会う。',
    'A little hello, a shared idea. Leave a moment of your day here.',
  ],
  '今天有什么想分享的？': ['今日は何を話しましょう？', 'What’s on your mind?'],
  '问候、反馈、灵感，都可以留在这里。': [
    '挨拶、フィードバック、アイデアを気軽に。',
    'Greetings, feedback and inspiration are all welcome.',
  ],
  '登录，加入这场对话': ['ログインして会話に参加', 'Sign in to join the conversation'],
  '可以自由浏览，登录后即可发布、回复和点赞。': [
    '閲覧は自由です。ログインして投稿、返信、いいね。',
    'Browse freely. Sign in to post, reply and like.',
  ],
  '问候': ['挨拶', 'Greeting'],
  '反馈': ['フィードバック', 'Feedback'],
  '灵感': ['アイデア', 'Idea'],
  '话题': ['話題', 'Topic'],
  '提及': ['メンション', 'Mention'],
  '用 #话题# 或 @用户名，找到同频的朋友。': [
    '#話題# や @ユーザー名 を使って会話に参加。',
    'Use #topic# or @username to join a conversation.',
  ],
  '广场周边': ['広場の周辺', 'Around the plaza'],
  '关于广场': ['広場について', 'About the plaza'],
  '热门话题': ['人気の話題', 'Trending topics'],
  '浏览友链': ['相互リンク一覧', 'Partner sites'],
  '申请友链': ['相互リンクを申請', 'Apply for a link exchange'],
  '刷新留言': ['投稿を更新', 'Refresh messages'],
  '搜索留言、用户或话题': ['メッセージ、ユーザー、話題を検索', 'Search messages, people or topics'],
  '清除搜索': ['検索をクリア', 'Clear search'],
  '查看全部留言': ['すべての投稿を表示', 'Show all messages'],
  '条留言': ['件', 'messages'],
  '留言墙': ['メッセージウォール', 'Message wall'],
  '公共留言墙': ['公開メッセージウォール', 'Public message wall'],
  '最新': ['最新', 'Latest'],
  '高赞': ['人気', 'Most liked'],
  '有回复': ['返信あり', 'With replies'],
  '我的': ['自分の投稿', 'Mine'],
  '最近活动': ['最近の活動', 'Recent activity'],
  '留言约定': ['投稿ルール', 'Community guidelines'],
  '项目仓库与更新记录': ['プロジェクトと更新履歴', 'Project repository and updates'],
  '文章、公告与创作手记': ['記事、お知らせ、制作ノート', 'Articles, announcements and creative notes'],
  '画像素画并分享到公开画廊': ['ピクセルアートを描いて共有', 'Draw pixel art and share it'],
  '站内文章': ['記事', 'Articles'],
  '注册访客': ['ユーザー', 'Members'],
  '广场留言': ['投稿', 'Messages'],
  '服务运行': ['稼働時間', 'Uptime'],
  '还没有话题，试试发布 #月读茶会#': [
    '最初の #話題# を投稿してみましょう。',
    'No topics yet. Try posting #TsukuyomiTea#',
  ],
  '还没有匹配的留言。': ['一致する投稿はありません。', 'No matching messages.'],
  '喜欢': ['いいね', 'Like'],
  '收起回复': ['返信を折りたたむ', 'Collapse replies'],
  '展开完整回复': ['返信の全文を表示', 'Read full reply'],
  '当前': ['表示中', 'Showing'],
  '第': ['ページ', 'Page'],
  '页': ['', ''],
  '共': ['全', 'of'],
};
