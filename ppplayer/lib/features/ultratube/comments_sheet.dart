import 'package:flutter/material.dart';

import '../../core/api/ultratube_catalog.dart';
import '../../core/theme/ultratube_theme.dart';
import 'yt_widgets.dart';

/// Comment text arrives as light HTML; show it as plain text.
String plainComment(String html) => html
    .replaceAll(RegExp(r'<br\s*/?>'), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
    .replaceAll('&nbsp;', ' ');

/// Comments of a video in a bottom sheet (Shorts). [countLabel] is YouTube's
/// own count ("157"), shown in the title when known.
Future<void> showCommentsSheet(BuildContext context, {required String url, String countLabel = ''}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: UT.surface1,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, controller) => _Comments(url: url, countLabel: countLabel, controller: controller),
      ),
    );

class _Comments extends StatefulWidget {
  const _Comments({required this.url, required this.countLabel, required this.controller});
  final String url;
  final String countLabel;
  final ScrollController controller;
  @override
  State<_Comments> createState() => _CommentsState();
}

class _CommentsState extends State<_Comments> {
  static const _catalog = UltratubeCatalog();
  List<YtComment> _comments = const [];
  String? _next;
  bool _loading = true;
  bool _loadingMore = false;
  bool _disabled = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final (items, next, disabled) = await _catalog.comments(widget.url);
      if (!mounted) return;
      setState(() {
        _comments = items;
        _next = next;
        _disabled = disabled;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _more() async {
    final token = _next;
    if (token == null || _loadingMore) return;
    _loadingMore = true;
    try {
      final (items, next) = await _catalog.moreComments(token);
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, ...items];
        _next = next;
      });
    } catch (_) {
      if (mounted) setState(() => _next = null);
    } finally {
      _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = Padding(
      padding: const EdgeInsets.fromLTRB(UT.s4, 0, UT.s4, UT.s3),
      child: Row(
        children: [
          const Text('Comentários', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          if (widget.countLabel.isNotEmpty) ...[
            const SizedBox(width: UT.s2),
            Text(widget.countLabel, style: const TextStyle(color: UT.text2, fontSize: 14)),
          ],
        ],
      ),
    );

    // Every state scrolls with the sheet's controller, so it can always be
    // dragged down to close.
    Widget message(Widget child) => ListView(
      controller: widget.controller,
      children: [
        title,
        Padding(padding: const EdgeInsets.all(UT.s8), child: Center(child: child)),
      ],
    );

    if (_loading) return message(const CircularProgressIndicator());
    if (_failed) return message(ErrorRetry(message: 'Não foi possível carregar os comentários.', onRetry: _load));
    if (_disabled) return message(const Text('Comentários desativados neste vídeo.', style: TextStyle(color: UT.text2)));
    if (_comments.isEmpty) return message(const Text('Ainda não há comentários.', style: TextStyle(color: UT.text2)));

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 600) _more();
        return false;
      },
      child: ListView.builder(
        controller: widget.controller,
        itemCount: _comments.length + 2,
        itemBuilder: (context, i) {
          if (i == 0) return title;
          if (i == _comments.length + 1) {
            return _next == null
                ? const SizedBox(height: UT.s8)
                : const Padding(padding: EdgeInsets.all(UT.s4), child: Center(child: CircularProgressIndicator()));
          }
          return _CommentTile(_comments[i - 1]);
        },
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile(this.comment);
  final YtComment comment;
  @override
  Widget build(BuildContext context) {
    final c = comment;
    return Padding(
      padding: const EdgeInsets.fromLTRB(UT.s4, UT.s2, UT.s4, UT.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Avatar(c.avatar, size: 32),
          const SizedBox(width: UT.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.pinned)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        Icon(Icons.push_pin_outlined, size: 12, color: UT.text2),
                        SizedBox(width: 4),
                        Text('Fixado', style: TextStyle(fontSize: 11.5, color: UT.text2)),
                      ],
                    ),
                  ),
                Text(
                  [c.author, c.uploaded].where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: UT.text2),
                ),
                const SizedBox(height: 2),
                Text(plainComment(c.text), style: const TextStyle(fontSize: 14, height: 1.35, color: UT.text)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.thumb_up_outlined, size: 14, color: UT.text2),
                    if (c.likes > 0) ...[
                      const SizedBox(width: 4),
                      Text(compactCount(c.likes), style: const TextStyle(fontSize: 12, color: UT.text2)),
                    ],
                    if (c.hearted) ...[
                      const SizedBox(width: UT.s3),
                      const Icon(Icons.favorite, size: 14, color: UT.red),
                    ],
                    if (c.replies > 0) ...[
                      const SizedBox(width: UT.s3),
                      Text(
                        '${c.replies} ${c.replies == 1 ? 'resposta' : 'respostas'}',
                        style: const TextStyle(fontSize: 12, color: UT.text2),
                      ),
                    ],
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
