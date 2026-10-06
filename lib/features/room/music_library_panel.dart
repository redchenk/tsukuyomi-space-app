import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/site_localization.dart';
import 'room_music.dart';

class MusicLibraryPanel extends StatefulWidget {
  const MusicLibraryPanel({super.key, required this.music});
  final RoomMusic music;
  @override
  State<MusicLibraryPanel> createState() => _PanelState();
}

class _PanelState extends State<MusicLibraryPanel> {
  bool _cloud = false;
  final _query = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.music.library.setOpen(true);
  }

  @override
  void dispose() {
    widget.music.library.setOpen(false);
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final music = widget.music, library = music.library;
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) => Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const SiteText('网站曲目'),
                selected: !_cloud,
                onSelected: (_) {
                  music.useLocal();
                  setState(() => _cloud = false);
                },
              ),
              ChoiceChip(
                label: const SiteText('网易云'),
                selected: _cloud,
                onSelected: (_) => setState(() => _cloud = true),
              ),
            ],
          ),
          if (library.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                library.error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: !_cloud
                ? ListView.builder(
                    itemCount: music.localTracks.length,
                    itemBuilder: (context, i) => ListTile(
                      selected: !music.remote && music.index == i,
                      leading: Text('${i + 1}'.padLeft(2, '0')),
                      title: Text('${music.localTracks[i]['title']}'),
                      onTap: () {
                        music.useLocal();
                        music.select(i);
                      },
                    ),
                  )
                : library.profile == null
                ? ListView(
                    children: [
                      const SizedBox(height: 16),
                      SiteText(
                        library.enabled
                            ? '使用网易云 App 扫码，歌曲只在你的音乐库中显示。'
                            : '网易云暂未启用，可以继续听网站曲目',
                      ),
                      if (library.enabled) ...[
                        if (library.qr != null)
                          Center(
                            child: QrImageView(
                              data: '${library.qr!['url']}',
                              size: 176,
                              backgroundColor: Colors.white,
                            ),
                          ),
                        if (library.qrStatus.isNotEmpty)
                          Center(
                            child: SiteText(switch (library.qrStatus) {
                              'scanned' => '已扫码，请在手机确认',
                              'expired' => '二维码已过期',
                              _ => '等待扫码',
                            }),
                          ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: library.busy ? null : library.login,
                          child: SiteText(
                            library.qr == null ? '扫码登录' : '刷新二维码',
                          ),
                        ),
                        if (library.qr != null)
                          TextButton(
                            onPressed: library.cancelQr,
                            child: const SiteText('取消'),
                          ),
                      ],
                    ],
                  )
                : Column(
                    children: [
                      Row(
                        children: [
                          _MusicCover(
                            url: '${library.profile!['avatar'] ?? ''}',
                            size: 28,
                            round: true,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${library.profile!['nickname'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: library.busy ? null : library.logout,
                            child: const SiteText('退出网易云'),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _query,
                              maxLength: 100,
                              decoration: InputDecoration(
                                hintText: siteTranslate(context, '输入歌名或歌手'),
                                counterText: '',
                              ),
                              onSubmitted: (_) {
                                library.query = _query.text;
                                library.browse('search');
                              },
                            ),
                          ),
                          IconButton(
                            tooltip: siteTranslate(context, '搜索'),
                            onPressed: library.busy
                                ? null
                                : () {
                                    library.query = _query.text;
                                    library.browse('search');
                                  },
                            icon: const Icon(Icons.search),
                          ),
                        ],
                      ),
                      TextButton(
                        onPressed: library.busy
                            ? null
                            : () => library.browse('playlists'),
                        child: const SiteText('我的歌单'),
                      ),
                      if (library.busy) const LinearProgressIndicator(),
                      Expanded(
                        child: ListView.builder(
                          itemCount: library.view == 'playlists'
                              ? library.playlists.length
                              : library.results.length,
                          itemBuilder: (context, i) {
                            final item = library.view == 'playlists'
                                ? library.playlists[i]
                                : library.results[i];
                            return ListTile(
                              leading: _MusicCover(
                                url: '${item['cover'] ?? ''}',
                              ),
                              title: Text(
                                '${item['title'] ?? item['name'] ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${item['artist'] ?? item['count'] ?? ''}',
                                maxLines: 1,
                              ),
                              onTap: library.busy
                                  ? null
                                  : () {
                                      if (library.view == 'playlists') {
                                        library.browse(
                                          'playlist',
                                          selectedPlaylist: item,
                                        );
                                      } else {
                                        library.play(item);
                                      }
                                    },
                            );
                          },
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            tooltip: siteTranslate(context, '上一页'),
                            onPressed: library.busy || library.offset == 0
                                ? null
                                : () => library.browse(
                                    library.view,
                                    page: library.offset - 20,
                                  ),
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Text('${library.offset ~/ 20 + 1}'),
                          IconButton(
                            tooltip: siteTranslate(context, '下一页'),
                            onPressed: library.busy || !library.more
                                ? null
                                : () => library.browse(
                                    library.view,
                                    page: library.offset + 20,
                                  ),
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _MusicCover extends StatelessWidget {
  const _MusicCover({required this.url, this.size = 34, this.round = false});
  final String url;
  final double size;
  final bool round;
  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(url);
    final fallback = Icon(
      round ? Icons.person_outline : Icons.music_note,
      size: size * .65,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(round ? size / 2 : 8),
      child: SizedBox(
        width: size,
        height: size,
        child:
            uri?.scheme == 'https' &&
                uri!.host.isNotEmpty &&
                uri.userInfo.isEmpty
            ? Image.network(
                url,
                fit: BoxFit.cover,
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (_, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }
}
