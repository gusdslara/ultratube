import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/ultratube_catalog.dart';
import '../../core/player/player_provider.dart';
import '../../core/services/settings_provider.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/ultratube/ultratube_store.dart';
import 'playlist_picker.dart';
import 'yt_widgets.dart';

/// Plays [items] from [start], optionally shuffled, opening the watch page.
Future<void> playItems(BuildContext context, WidgetRef ref, List<YtItem> items, {int start = 0, bool shuffle = false}) async {
  final playable = [for (final i in items) if (i.videoId != null && !i.shorts) i];
  if (playable.isEmpty) return;
  final ordered = shuffle ? ([...playable]..shuffle()) : playable;
  final first = shuffle ? 0 : start.clamp(0, ordered.length - 1);
  final tracks = [for (final i in ordered) i.toTrack()];
  final settings = ref.read(settingsProvider);
  if (settings.showVideo) await ref.read(settingsProvider.notifier).setPlayerView(PlayerView.video);
  await ref.read(playerProvider.notifier).playTrack(tracks[first], queue: tracks, queueIndex: first);
  if (context.mounted && settings.showVideo) {
    context.push('/watch?v=${ordered[first].videoId}', extra: ordered[first]);
  }
}

/// Playlist page for a YouTube playlist ([url]) or a local one ([localId]).
class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({super.key, this.url, this.localId}) : assert(url != null || localId != null);
  final String? url;
  final String? localId;
  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  static const _catalog = UltratubeCatalog();
  YtPlaylist? _remote;
  final List<YtItem> _items = [];
  String? _next;
  String? _error;
  bool _loading = false;

  bool get _isLocal => widget.localId != null;

  @override
  void initState() {
    super.initState();
    if (!_isLocal) _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final p = await _catalog.playlist(widget.url!);
      if (!mounted) return;
      setState(() {
        _remote = p;
        _items
          ..clear()
          ..addAll(p.page.items);
        _next = p.page.next;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    if (_next == null || _loading) return;
    setState(() => _loading = true);
    try {
      final page = await _catalog.more(_next!);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _next = page.next;
      });
    } catch (_) {
      _next = null;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Loads every page before "play all"/"shuffle" so the queue is complete.
  Future<List<YtItem>> _all() async {
    var guard = 0;
    while (_next != null && guard++ < 20) {
      await _more();
    }
    return _items;
  }

  Future<void> _playAll(List<YtItem> items, {bool shuffle = false}) async {
    final all = _isLocal ? items : await _all();
    if (!mounted) return;
    await playItems(context, ref, all, shuffle: shuffle);
  }

  @override
  Widget build(BuildContext context) {
    final local = _isLocal
        ? ref.watch(playlistsProvider).where((p) => p.id == widget.localId).firstOrNull
        : null;
    final likedPseudo = widget.localId == 'liked';
    final liked = likedPseudo ? ref.watch(likedProvider) : const <YtItem>[];
    final items = likedPseudo ? liked : (local?.items ?? _items);
    final title = likedPseudo ? 'Vídeos curtidos' : (local?.title ?? _remote?.title ?? '');
    final cover = items.isNotEmpty ? items.first.bestCover : (_remote?.cover ?? '');
    final subtitle = likedPseudo || local != null
        ? '${items.length} vídeos · neste aparelho'
        : [
            _remote?.channel ?? '',
            if ((_remote?.count ?? -1) >= 0) '${_remote!.count} vídeos',
          ].where((s) => s.isNotEmpty).join(' · ');
    final saved = !_isLocal && ref.watch(savedPlaylistsProvider).any((p) => p.url == widget.url);

    if (_isLocal && local == null && !likedPseudo) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Playlist não encontrada')));
    }

    return Scaffold(
      body: _error != null && items.isEmpty
          ? SafeArea(child: Center(child: ErrorRetry(message: 'Não foi possível abrir a playlist.', onRetry: _load)))
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (!_isLocal && n.metrics.extentAfter < 900) _more();
                return false;
              },
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _Hero(
                      cover: cover,
                      title: title,
                      subtitle: subtitle,
                      actions: [
                        if (!_isLocal)
                          IconButton.filledTonal(
                            tooltip: saved ? 'Remover da biblioteca' : 'Salvar na biblioteca',
                            style: IconButton.styleFrom(backgroundColor: Colors.white12),
                            icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
                            onPressed: () => ref.read(savedPlaylistsProvider.notifier).toggle(
                              YtItem(kind: YtKind.playlist, url: widget.url!, title: title, cover: cover, channel: _remote?.channel ?? '', videos: _remote?.count ?? -1),
                            ),
                          ),
                        if (local != null)
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (v) async {
                              if (v == 'rename') await renamePlaylist(context, ref, local);
                              if (v == 'delete') {
                                ref.read(playlistsProvider.notifier).delete(local.id);
                                if (context.mounted) context.pop();
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'rename', child: Text('Renomear')),
                              PopupMenuItem(value: 'delete', child: Text('Excluir playlist')),
                            ],
                          ),
                      ],
                      onPlay: items.isEmpty ? null : () => _playAll(items),
                      onShuffle: items.isEmpty ? null : () => _playAll(items, shuffle: true),
                    ),
                  ),
                  if (_loading && items.isEmpty)
                    const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(UT.s8), child: Center(child: CircularProgressIndicator())))
                  else if (items.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(UT.s8),
                        child: Center(child: Text('Nenhum vídeo ainda.\nUse ⋮ → Salvar em playlist.', textAlign: TextAlign.center, style: TextStyle(color: UT.text2))),
                      ),
                    )
                  else if (local != null)
                    SliverReorderableList(
                      itemCount: items.length,
                      onReorder: (a, b) => ref.read(playlistsProvider.notifier).reorder(local.id, a, b),
                      itemBuilder: (context, i) => Dismissible(
                        key: ValueKey(items[i].url),
                        direction: DismissDirection.endToStart,
                        background: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: UT.s6), color: UT.redSoft, child: const Icon(Icons.delete_outline, color: UT.red)),
                        onDismissed: (_) => ref.read(playlistsProvider.notifier).remove(local.id, items[i]),
                        child: ReorderableDelayedDragStartListener(
                          index: i,
                          child: VideoRow(items[i], onTap: () => playItems(context, ref, items, start: i)),
                        ),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) => VideoRow(
                        items[i],
                        onTap: () => playItems(context, ref, items, start: i),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: _loading && items.isNotEmpty
                        ? const Padding(padding: EdgeInsets.all(UT.s5), child: Center(child: CircularProgressIndicator()))
                        : const SizedBox(height: 140),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.cover, required this.title, required this.subtitle, required this.actions, this.onPlay, this.onShuffle});
  final String cover;
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Ambient backdrop from the artwork, fading into pure black.
        Positioned.fill(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: Opacity(opacity: 0.45, child: NetImage(cover)),
          ),
        ),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x66000000), UT.bg],
                stops: [0, 0.92],
              ),
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(UT.s4, UT.s1, UT.s4, UT.s5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(tooltip: 'Voltar', icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
                    const Spacer(),
                    ...actions,
                  ],
                ),
                const SizedBox(height: UT.s2),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(UT.rLg),
                      child: AspectRatio(aspectRatio: 16 / 9, child: NetImage(cover, icon: Icons.playlist_play)),
                    ),
                  ),
                ),
                const SizedBox(height: UT.s5),
                Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1.1)),
                const SizedBox(height: UT.s2),
                Text(subtitle, style: const TextStyle(color: UT.text2, fontSize: 13)),
                const SizedBox(height: UT.s4),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onPlay,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Reproduzir tudo'),
                      ),
                    ),
                    const SizedBox(width: UT.s3),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), backgroundColor: Colors.white10, side: BorderSide.none),
                        onPressed: onShuffle,
                        icon: const Icon(Icons.shuffle),
                        label: const Text('Aleatório'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
