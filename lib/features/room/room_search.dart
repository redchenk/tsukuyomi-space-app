import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/room_archive.dart';
import 'room_controller.dart';

Future<void> showRoomSearch(
  BuildContext context,
  RoomController c,
  ValueChanged<String> go,
) => showDialog<void>(
  context: context,
  builder: (_) => _RoomSearch(c: c, go: go),
);

class _RoomSearch extends StatefulWidget {
  const _RoomSearch({required this.c, required this.go});
  final RoomController c;
  final ValueChanged<String> go;
  @override
  State<_RoomSearch> createState() => _RoomSearchState();
}

class _RoomSearchState extends State<_RoomSearch> {
  static const destinations = {
    '/room': '私人居所',
    '/stage': '主舞台 文章',
    '/plaza': '月读广场',
    '/wiki': '百科',
    '/growth': '月契成长',
    '/conversations': '会话与记忆',
    '/user': '个人中心',
  };
  Timer? timer;
  int ticket = 0;
  String query = '', error = '';
  bool loading = false;
  List<Map<String, dynamic>> articles = [];
  void search(String value) {
    timer?.cancel();
    final run = ++ticket;
    setState(() {
      query = value.trim();
      error = '';
      articles = [];
      loading = query.isNotEmpty;
    });
    if (query.isNotEmpty) {
      timer = Timer(const Duration(milliseconds: 300), () => load(run));
    }
  }

  Future<void> load(int run) async {
    try {
      final result = await widget.c.workspace.request(
        'GET',
        '/api/articles?q=${Uri.encodeQueryComponent(query)}&limit=4&page=1&sort=featured',
      );
      if (mounted && run == ticket) {
        setState(
          () => articles = jsonRows(result['articles'] ?? result['data']),
        );
      }
    } catch (e) {
      if (mounted && run == ticket) {
        setState(() => error = e is ApiFailure ? e.message : '搜索暂不可用，请重试');
      }
    } finally {
      if (mounted && run == ticket) setState(() => loading = false);
    }
  }

  void go(String path) {
    Navigator.pop(context);
    widget.go(path);
  }

  @override
  void dispose() {
    timer?.cancel();
    ++ticket;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 580,
      height: MediaQuery.sizeOf(context).height * .72,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('搜索月读空间', style: TextStyle(fontSize: 22)),
                ),
                IconButton(
                  tooltip: '关闭搜索',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(CupertinoIcons.xmark),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              maxLength: 120,
              onChanged: search,
              onSubmitted: (_) {
                if (query.isNotEmpty) {
                  go('/stage?q=${Uri.encodeQueryComponent(query)}');
                }
              },
              decoration: const InputDecoration(
                hintText: '搜索页面、文章与内容',
                prefixIcon: Icon(CupertinoIcons.search),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  const Text('快捷入口', style: TextStyle(fontSize: 12)),
                  for (final entry in destinations.entries.where(
                    (v) =>
                        query.isEmpty ||
                        v.value.contains(query) ||
                        v.key.contains(query.toLowerCase()),
                  ))
                    ListTile(
                      title: Text(entry.value),
                      subtitle: Text(entry.key),
                      trailing: const Icon(
                        CupertinoIcons.arrow_right,
                        size: 16,
                      ),
                      onTap: () => go(entry.key),
                    ),
                  if (query.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('文章', style: TextStyle(fontSize: 12)),
                    ),
                    if (loading)
                      const LinearProgressIndicator()
                    else if (error.isNotEmpty)
                      ListTile(
                        title: Text(error),
                        trailing: TextButton(
                          onPressed: () => search(query),
                          child: const Text('重试'),
                        ),
                      )
                    else if (articles.isEmpty)
                      const ListTile(title: Text('没有找到相关文章')),
                    for (final item in articles)
                      ListTile(
                        title: Text('${item['title']}'),
                        leading: const Icon(CupertinoIcons.book),
                        onTap: () => go(
                          '/articles/${Uri.encodeComponent('${item['id']}')}',
                        ),
                      ),
                    if (articles.isNotEmpty)
                      TextButton(
                        onPressed: () =>
                            go('/stage?q=${Uri.encodeQueryComponent(query)}'),
                        child: const Text('查看全部文章结果'),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
