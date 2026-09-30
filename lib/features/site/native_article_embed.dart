import '../../core/site_localization.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// A sandboxed third-party frame. The article itself stays a native widget tree.
class NativeArticleEmbed extends StatefulWidget {
  const NativeArticleEmbed({
    super.key,
    required this.url,
    required this.title,
    required this.height,
    required this.onOpen,
  });
  final String url, title;
  final double height;
  final VoidCallback onOpen;
  @override
  State<NativeArticleEmbed> createState() => _NativeArticleEmbedState();
}

class _NativeArticleEmbedState extends State<NativeArticleEmbed> {
  bool opened = false, loading = false;
  String error = '';
  bool get supported => kIsWeb || defaultTargetPlatform != TargetPlatform.linux;
  @override
  void didUpdateWidget(covariant NativeArticleEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      opened = false;
      loading = false;
      error = '';
    }
  }

  String get markup {
    final escape = const HtmlEscape().convert;
    final sameOrigin = Uri.parse(widget.url).host == 'player.bilibili.com'
        ? ' allow-same-origin'
        : '';
    return '<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>html,body{margin:0;width:100%;height:100%;background:transparent}iframe{border:0;width:100%;height:100%}</style></head><body><iframe src="${escape(widget.url)}" title="${escape(widget.title)}" sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-presentation$sameOrigin" referrerpolicy="strict-origin-when-cross-origin" allow="fullscreen; picture-in-picture; encrypted-media" allowfullscreen></iframe></body></html>';
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (opened && error.isEmpty)
        SizedBox(
          height: widget.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: InAppWebView(
                  key: ValueKey(widget.url),
                  initialData: InAppWebViewInitialData(data: markup),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    useShouldOverrideUrlLoading: true,
                    mediaPlaybackRequiresUserGesture: true,
                    allowsInlineMediaPlayback: true,
                    allowFileAccess: false,
                    allowFileAccessFromFileURLs: false,
                    allowUniversalAccessFromFileURLs: false,
                    mixedContentMode:
                        MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                    transparentBackground: true,
                  ),
                  shouldOverrideUrlLoading: (_, navigation) async {
                    final url = navigation.request.url;
                    if (url == null ||
                        !['https', 'about'].contains(url.scheme)) {
                      return NavigationActionPolicy.CANCEL;
                    }
                    if (navigation.isForMainFrame && url.scheme == 'https') {
                      widget.onOpen();
                      return NavigationActionPolicy.CANCEL;
                    }
                    return NavigationActionPolicy.ALLOW;
                  },
                  onPermissionRequest: (_, request) async => PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.DENY,
                  ),
                  onLoadStop: (_, _) {
                    if (mounted) setState(() => loading = false);
                  },
                  onReceivedError: (_, request, failure) {
                    if (mounted && request.isForMainFrame == true) {
                      setState(() {
                        error = failure.description;
                        loading = false;
                      });
                    }
                  },
                ),
              ),
              if (loading)
                const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        )
      else
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              const Icon(Icons.web_asset, size: 36),
              const SizedBox(height: 12),
              Text(
                widget.title.isEmpty
                    ? Uri.parse(widget.url).host
                    : widget.title,
              ),
              if (error.isNotEmpty) Text('嵌入内容加载失败：$error'),
              if (!supported) const SiteText('当前平台可通过浏览器打开此嵌入内容'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  if (supported)
                    FilledButton(
                      onPressed: () => setState(() {
                        opened = true;
                        loading = true;
                        error = '';
                      }),
                      child: Text(error.isEmpty ? '加载嵌入内容' : '重试'),
                    ),
                  TextButton(
                    onPressed: widget.onOpen,
                    child: const SiteText('打开原链接'),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (opened)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(child: Text(widget.title)),
              IconButton(
                onPressed: widget.onOpen,
                tooltip: siteTranslate(context, '打开原链接'),
                icon: const Icon(Icons.open_in_new),
              ),
            ],
          ),
        ),
    ],
  );
}
