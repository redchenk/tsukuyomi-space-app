import 'package:flutter/widgets.dart';

import '../../core/site_localization.dart';

const _copy = <String, (String, String, String)>{
  'title': ('应用更新', 'App updates', 'アプリの更新'),
  'intro': ('让月读空间保持最新', 'Keep Tsukuyomi Space up to date', '月読空間を最新の状態に'),
  'description': (
    '从官方 GitHub 获取新版本，下载完成并校验后，由你确认安装。聊天记录与模型配置会保留。',
    'Get new releases from official GitHub. Downloads are verified before you confirm installation. Your chats and model settings are preserved.',
    '公式 GitHub から新バージョンを取得します。ダウンロードと検証の後、インストールを確認してください。会話とモデル設定は保持されます。',
  ),
  'current': ('当前版本', 'Installed version', '現在のバージョン'),
  'latest': (
    '已是当前渠道最新版本',
    'You are up to date on this channel',
    'このチャンネルの最新バージョンです',
  ),
  'check': ('检查更新', 'Check for updates', '更新を確認'),
  'checking': (
    '正在检查 GitHub 新版本…',
    'Checking GitHub releases…',
    'GitHub のリリースを確認中…',
  ),
  'new': ('有新版本可用', 'An update is available', '新バージョンがあります'),
  'view': ('查看更新', 'View update', '更新を表示'),
  'download': ('下载更新', 'Download update', '更新をダウンロード'),
  'downloading': ('正在下载更新…', 'Downloading update…', '更新をダウンロード中…'),
  'cancel': ('取消下载', 'Cancel download', 'ダウンロードを中止'),
  'verifying': ('正在校验安装包…', 'Verifying the installer…', 'インストーラーを検証中…'),
  'ready': (
    '下载完成，SHA-256 校验通过',
    'Downloaded and SHA-256 verified',
    'ダウンロードと SHA-256 検証が完了',
  ),
  'install': ('安装更新', 'Install update', '更新をインストール'),
  'open': ('打开安装包', 'Open installer', 'インストーラーを開く'),
  'share': ('导出 IPA', 'Export IPA', 'IPA を書き出す'),
  'later': ('此版本稍后提醒', 'Remind me later for this version', 'このバージョンは後で通知'),
  'automatic': ('自动检查新版本', 'Automatically check for updates', '更新を自動確認'),
  'automaticNote': (
    '启动和回到前台时检查，每天最多一次；不会自动下载或安装。',
    'Check on launch and resume, at most once a day. Download and installation require your choice.',
    '起動時と復帰時に、最大 1 日 1 回確認します。ダウンロードとインストールは任意です。',
  ),
  'previews': ('接收预览版', 'Include preview releases', 'プレビュー版を受け取る'),
  'previewNote': (
    '关闭后只检查正式版本。预览版可能包含仍在完善的功能。',
    'Turn off to check stable releases only. Preview features may still be in development.',
    'オフにすると正式版のみ確認します。プレビュー版には開発中の機能が含まれます。',
  ),
  'notes': ('更新内容', 'What’s new', '更新内容'),
  'github': ('在 GitHub 查看发布', 'View release on GitHub', 'GitHub でリリースを表示'),
  'source': (
    '下载来源：官方 GitHub · 安装前校验 SHA-256',
    'Source: official GitHub · SHA-256 verified before installation',
    '配信元：公式 GitHub · インストール前に SHA-256 を検証',
  ),
  'untrusted': (
    '更新来源不可信，已阻止下载和安装。请在官方 GitHub 查看。',
    'The update source is not trusted. Download and installation were blocked. Check official GitHub.',
    '更新の配信元を確認できないため、ダウンロードとインストールを中止しました。公式 GitHub を確認してください。',
  ),
  'confirm': ('准备安装新版本', 'Ready to install the update', '更新のインストール'),
  'save': (
    '请先保存正在编辑的内容，并结束聊天或 Agent 任务。安装过程中可能需要关闭应用；完成后重新打开即可。',
    'Save your edits and finish any chat or Agent task first. The installer may ask you to close the app. Reopen it after installation.',
    '編集中の内容を保存し、会話や Agent のタスクを終了してください。インストール中にアプリを閉じる必要がある場合があります。完了後、再び開いてください。',
  ),
  'continue': ('继续安装', 'Continue', '続行'),
  'back': ('返回', 'Back', '戻る'),
  'installing': (
    '正在打开系统安装器…',
    'Opening the system installer…',
    'システムのインストーラーを起動中…',
  ),
  'opened': (
    '安装器已打开。请在系统窗口中完成更新，再重新打开月读空间。',
    'The installer is open. Complete the update in the system window, then reopen Tsukuyomi Space.',
    'インストーラーを開きました。システムの画面で更新を完了し、月読空間を再び開いてください。',
  ),
  'permission': (
    '请允许月读空间安装应用，返回这里后再次点击“安装更新”。',
    'Allow Tsukuyomi Space to install apps, then return here and tap Install update again.',
    '月読空間によるアプリのインストールを許可し、戻って「更新をインストール」を押してください。',
  ),
  'macos': (
    '打开 DMG 后，将月读空间拖到 Applications 并替换旧版，再重新打开。',
    'Open the DMG, drag Tsukuyomi Space to Applications, replace the old version, and reopen.',
    'DMG を開き、月読空間を Applications にドラッグして旧版を置き換え、再び開いてください。',
  ),
  'linux': (
    '将通过系统软件安装器打开 DEB。适用于 Debian / Ubuntu；如果系统没有安装器，请从 GitHub 获取安装说明。',
    'The DEB opens in your system package installer on Debian / Ubuntu. If no installer is available, see the installation guide on GitHub.',
    'Debian / Ubuntu のパッケージインストーラーで DEB を開きます。利用できない場合は GitHub のインストール手順を確認してください。',
  ),
  'ios': (
    '当前 iOS 包为未签名 IPA。下载后导出到签名工具，使用自己的证书签名并安装；无法在应用内直接覆盖安装。',
    'The iOS release is an unsigned IPA. Export it to your signing tool, sign with your own certificate, then install. Direct in-app installation is unavailable.',
    'iOS 版は未署名の IPA です。署名ツールに書き出し、ご自身の証明書で署名してインストールしてください。アプリ内の直接インストールには対応していません。',
  ),
  'iosOpened': (
    '请在分享菜单中保存 IPA 或交给签名工具，签名后安装。',
    'Save or send the IPA to your signing tool from the share sheet, then sign and install it.',
    '共有メニューで IPA を保存するか署名ツールに送り、署名してインストールしてください。',
  ),
  'network': (
    '暂时无法连接 GitHub，请检查网络后重试。',
    'Cannot connect to GitHub. Check your connection and try again.',
    'GitHub に接続できません。接続を確認して再試行してください。',
  ),
  'rateLimit': (
    'GitHub 暂时限制了检查请求，请稍后重试。',
    'GitHub temporarily limited requests. Please try again later.',
    'GitHub のリクエスト制限に達しました。後で再試行してください。',
  ),
  'metadata': (
    '发布信息不完整，请稍后重试或在 GitHub 查看。',
    'The release information is incomplete. Try later or check GitHub.',
    'リリース情報が不完全です。後で再試行するか GitHub を確認してください。',
  ),
  'integrity': (
    '安装包校验未通过，已阻止安装。请重新下载。',
    'Installer verification failed. Installation was blocked. Download it again.',
    'インストーラーの検証に失敗したため、インストールを中止しました。再ダウンロードしてください。',
  ),
  'storage': (
    '无法保存安装包，请检查剩余空间和文件权限。',
    'Cannot save the installer. Check disk space and file permissions.',
    'インストーラーを保存できません。空き容量と権限を確認してください。',
  ),
  'installer': (
    '系统未能打开安装器。可重试，或在 GitHub 按安装说明更新。',
    'The system could not open the installer. Retry or follow the installation guide on GitHub.',
    'インストーラーを起動できません。再試行するか GitHub の手順を確認してください。',
  ),
  'unsupported': (
    '尚未提供适用于此设备架构的更新包。',
    'No update package is available for this device architecture.',
    'この端末のアーキテクチャに対応した更新パッケージはありません。',
  ),
  'signing': (
    '新版与当前应用签名不同，无法覆盖安装。开发调试版请先通过官方发布包安装；卸载前请备份本地记录。',
    'The update uses a different signing certificate. It cannot replace this app. For a debug build, install the official release; back up local chats before uninstalling.',
    '署名が異なるため更新できません。デバッグ版の場合は公式リリースをインストールしてください。アンインストール前に会話をバックアップしてください。',
  ),
  'package': (
    '安装包与当前应用不匹配，已阻止安装。',
    'The installer does not match this app. Installation was blocked.',
    'パッケージがこのアプリと一致しないため、インストールを中止しました。',
  ),
  'downgrade': (
    '安装包并不比当前应用更新，已阻止安装。',
    'The package is not newer than this app. Installation was blocked.',
    '現在のアプリより新しくないため、インストールを中止しました。',
  ),
};

String updateText(BuildContext context, String key) {
  final value = _copy[key] ?? _copy['installer']!;
  return switch (SiteLocaleScope.maybeOf(context)?.language) {
    'en' => value.$2,
    'ja' => value.$3,
    _ => value.$1,
  };
}
