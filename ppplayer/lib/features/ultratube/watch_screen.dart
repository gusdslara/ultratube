import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fullscreen_window/fullscreen_window.dart';
import 'package:go_router/go_router.dart';

import '../../core/ai/video_assistant.dart';
import '../../core/api/ultratube_catalog.dart';
import '../../core/downloads/ultratube_downloads.dart';
import '../../core/live/live_chat.dart';
import '../../core/player/player_provider.dart';
import '../../core/player/video_layout_provider.dart';
import '../../core/services/settings_provider.dart';
import '../../core/ultratube/ultratube_platform.dart';
import '../../core/ultratube/ultratube_store.dart';
import '../../core/theme/ultratube_theme.dart';
import '../downloads/track_actions_button.dart';
import '../live/live_chat_view.dart';
import '../player/player_providers.dart';
import 'ask_sheet.dart';
import 'pip_button.dart';
import 'playlist_picker.dart';
import 'queue_sheet.dart';
import 'video_menu_sheet.dart';
import 'comments_sheet.dart' show plainComment;
import 'yt_widgets.dart';

/// YouTube-style watch page. The video itself is the app-wide playback
/// surface, positioned under the transparent [_slot] of this page.
class WatchScreen extends ConsumerStatefulWidget {
  const WatchScreen({super.key, required this.videoId, this.item});
  final String videoId;
  final YtItem? item;
  @override
  ConsumerState<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends ConsumerState<WatchScreen> with WidgetsBindingObserver {
  static const _catalog = UltratubeCatalog();
  final _slot = GlobalKey();
  final _scroll = ScrollController();
  late String _id = widget.videoId;
  YtItem? _item;
  YtVideo? _video;
  String? _error;
  bool _fullscreen = false;
  bool _portraitLocked = false;
  late VideoLayoutNotifier _layout;
  int _generation = 0;

  /// Chat + audience counter while a live stream is open.
  YouTubeLiveSession? _live;

  bool get _isLive => _video?.item.live ?? _item?.live ?? false;

  /// Starts/stops the live session to match the open video.
  void _syncLive() {
    final want = _isLive ? _id : null;
    if (_live?.videoId == want) return;
    final old = _live;
    _live = want == null ? null : YouTubeLiveSession(want);
    // Let listeners detach during this frame before tearing the old one down.
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _layout = ref.read(videoLayoutProvider.notifier);
    _item = widget.item;
    _open(_id, widget.item, startPlayback: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_fullscreen || _portraitLocked) _restoreSystemUi();
    _scroll.dispose();
    _live?.dispose();
    Future<void>.microtask(_layout.clear);
    super.dispose();
  }

  VideoContext _askContext() {
    final item = _item;
    final video = _video;
    return VideoContext(
      videoId: _id,
      title: item?.title ?? '',
      channel: item?.channel ?? '',
      description: video?.description ?? '',
      durationSeconds: item?.duration ?? 0,
      views: _isLive ? (_live?.viewers.value ?? -1) : (item?.views ?? -1),
      uploaded: item == null || _isLive ? '' : uploadedLabel(item),
      live: _isLive,
      related: [
        for (final r in video?.related ?? const <YtItem>[])
          if (r.kind == YtKind.video && !r.shorts) '${r.title} — ${r.channel}',
      ],
      recentChat: [
        for (final m in (_live?.chat.messages ?? const <ChatMessage>[]).reversed.take(120).toList().reversed) '${m.author}: ${m.plain}',
      ],
    );
  }

  void _openAsk() => showAskSheet(
    context,
    video: _askContext,
    onSeek: _isLive
        ? null
        : (at) {
            final player = ref.read(playerProvider.notifier);
            player.seekTo(at);
            if (!ref.read(playerProvider).isPlaying) player.togglePlay();
          },
  );

  @override
  void didChangeMetrics() => _measure();

  void _measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _slot.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final position = box.localToGlobal(Offset.zero);
      final old = ref.read(videoLayoutProvider);
      if (old.size != box.size || old.position != position || !old.isVisible) {
        _layout.updateLayout(box.size, position, isVisible: true, label: 'ultratube_watch');
      }
    });
  }

  Future<void> _open(String id, YtItem? item, {required bool startPlayback, bool keepContext = false}) async {
    final generation = ++_generation;
    setState(() {
      _id = id;
      _item = item ?? _item;
      _video = null;
      _error = null;
      _syncLive();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    final player = ref.read(playerProvider.notifier);
    final current = ref.read(playerProvider).currentTrack?.youtubeVideoId;
    if (startPlayback && current != id) {
      // Picture on, unless the viewer chose "Só áudio" (that choice sticks
      // across videos; setPlayerView keeps showVideo in sync).
      await ref.read(settingsProvider.notifier).setPlayerView(
        ref.read(audioOnlyProvider) ? PlayerView.artwork : PlayerView.video,
      );
      final track = (item ?? YtItem(kind: YtKind.video, url: 'https://www.youtube.com/watch?v=$id', title: '')).toTrack();
      // Goes in right after the current item; the queue is kept.
      unawaited(player.playNow(track, keepContext: keepContext));
    }
    try {
      final video = await _catalog.video('https://www.youtube.com/watch?v=$id');
      if (!mounted || generation != _generation) return;
      setState(() {
        _video = video;
        _item = video.item;
        _syncLive();
      });
      ref.read(historyProvider.notifier).add(video.item);
      // Nothing queued after this video: its "up next" becomes the queue
      // (as automatic items, so anything the viewer adds plays before them).
      final state = ref.read(playerProvider);
      if (state.currentTrack?.youtubeVideoId == id && state.queue.length - state.currentIndex <= 1) {
        player.addAutoplayTracks([
          for (final r in video.related.where((r) => r.videoId != null && !r.shorts && !r.live).take(10)) r.toTrack(),
        ]);
      }
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = '$error');
    }
  }

  void _play(YtItem item) {
    if (item.shorts || item.videoId == null) {
      openItem(context, item);
      return;
    }
    // Picked on the watch page: the playlist/queue being played continues after it.
    _open(item.videoId!, item, startPlayback: true, keepContext: true);
  }

  Future<void> _toggleFullscreen() async {
    // Desktop: real window fullscreen, shared with the F shortcut.
    if (isUltratubeDesktop) {
      final next = !ref.read(isFullscreenProvider);
      ref.read(isFullscreenProvider.notifier).setFullscreen(next);
      await FullScreenWindow.setFullScreen(next);
      if (mounted) setState(() => _fullscreen = next);
      _measure();
      return;
    }
    // In landscape the exit button returns to portrait.
    // Kept until the page closes (restored in dispose), so the phone doesn't
    // flip straight back while still held sideways.
    if (!_fullscreen && MediaQuery.orientationOf(context) == Orientation.landscape) {
      _portraitLocked = true;
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      return;
    }
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    ref.read(isFullscreenProvider.notifier).setFullscreen(next);
    if (next) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      await _restoreSystemUi();
    }
    _measure();
  }

  Future<void> _restoreSystemUi() async {
    ref.read(isFullscreenProvider.notifier).setFullscreen(false);
    if (isUltratubeDesktop) {
      await FullScreenWindow.setFullScreen(false);
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  @override
  Widget build(BuildContext context) {
    // Follow autoplay: when the queue advances, show the new video here.
    ref.listen(playerProvider.select((s) => s.currentTrack?.youtubeVideoId), (prev, next) {
      if (next != null && next != _id && mounted) {
        final track = ref.read(playerProvider).currentTrack!;
        _open(next, YtItem.fromTrack(track), startPlayback: false);
      }
    });
    _measure();
    // "A seguir" below is the queue: redraw when it changes.
    ref.watch(playerProvider.select((s) => s.playbackQueue));
    final colors = Theme.of(context).colorScheme;
    // Phones: rotating to landscape goes full screen, like YouTube (a 16:9
    // slot plus details cannot fit). Desktop windows are landscape by nature:
    // only the fullscreen button / F key goes immersive there.
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final immersive = isUltratubeDesktop ? ref.watch(isFullscreenProvider) : (_fullscreen || landscape);
    final size = MediaQuery.sizeOf(context);
    // Wide windows: the player is capped so details stay visible, and from
    // 1280 px "up next" moves to a side column like YouTube on desktop.
    final wide = size.width >= 900;
    final split = size.width >= 1280;
    final maxPlayerWidth = ((size.height - 230) * 16 / 9).clamp(480.0, 1280.0);
    final video = _VideoSlot(
      slotKey: _slot,
      item: _item,
      fullscreen: immersive,
      onFullscreen: _toggleFullscreen,
      live: _isLive,
      session: _live,
    );

    return PopScope(
      canPop: !(isUltratubeDesktop ? immersive : _fullscreen),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: immersive
            ? video
            : SafeArea(
                bottom: false,
                child: !wide
                    ? Column(
                        children: [
                          AspectRatio(aspectRatio: 16 / 9, child: video),
                          Expanded(child: ColoredBox(color: colors.surface, child: _details(context))),
                        ],
                      )
                    : ColoredBox(
                        color: colors.surface,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(maxWidth: maxPlayerWidth),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(UT.s4, UT.s4, UT.s4, 0),
                                    child: Column(
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(UT.rMd),
                                          child: AspectRatio(aspectRatio: 16 / 9, child: video),
                                        ),
                                        Expanded(child: _details(context, related: !split)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (split) SizedBox(width: 400, child: _upNext()),
                          ],
                        ),
                      ),
              ),
      ),
    );
  }

  /// "Up next" column for wide windows.
  Widget _upNext() {
    if (_video == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, UT.s2, UT.s4, 120),
      children: _nextRows(),
    );
  }

  static const _queueShown = 20;

  /// "A seguir" is the queue itself — what really plays next, in order
  /// (playlist, what the viewer queued, then automatic suggestions) —
  /// followed by the related videos that are not in it.
  List<Widget> _nextRows() {
    final state = ref.read(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final rows = <Widget>[];
    final queued = <String>{};
    if (state.currentTrack?.youtubeVideoId == _id) {
      final queue = state.queue;
      for (var i = state.currentIndex + 1; i < queue.length; i++) {
        final t = queue[i];
        final id = t.youtubeVideoId;
        if (id == null) continue;
        queued.add(id);
        if (rows.length < _queueShown) {
          rows.add(
            VideoRow(
              YtItem.fromTrack(t),
              key: ValueKey('queue:${t.queueItemId ?? i}'),
              onTap: () => notifier.skipTo(i),
            ),
          );
        }
      }
      if (queued.isNotEmpty) {
        rows.insert(
          0,
          _SectionHeader(
            'A seguir',
            detail: state.isShuffled ? 'ordem aleatória' : '${queued.length} na fila',
            onQueue: () => showQueueSheet(context),
          ),
        );
        if (queued.length > rows.length - 1) {
          rows.add(
            ListTile(
              dense: true,
              leading: const Icon(Icons.queue_music, color: UT.text2),
              title: Text('Ver a fila inteira (${queued.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
              onTap: () => showQueueSheet(context),
            ),
          );
        }
      }
    }
    final related = [
      for (final r in _video?.related ?? const <YtItem>[])
        if (r.videoId == null || (r.videoId != _id && !queued.contains(r.videoId))) r,
    ];
    if (related.isNotEmpty) rows.add(const _SectionHeader('Relacionados'));
    for (final r in related) {
      rows.add(r.kind == YtKind.channel ? ChannelTile(r) : VideoRow(r, onTap: () => _play(r)));
    }
    return rows;
  }

  Widget _details(BuildContext context, {bool related = true}) {
    final colors = Theme.of(context).colorScheme;
    final item = _item;
    final video = _video;
    if (item == null && _error != null) {
      return Center(child: ErrorRetry(message: 'Não foi possível abrir o vídeo.', onRetry: () => _open(_id, null, startPlayback: false)));
    }
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: video == null ? null : () => _description(context, video),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item?.title ?? '',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.25),
                      ),
                      const SizedBox(height: 6),
                      if (_isLive && _live != null)
                        _LiveMetaLine(session: _live!, more: video != null)
                      else
                        Text(
                          [
                            if (item != null) viewsLabel(item.views, live: item.live),
                            if (item != null && !item.live) uploadedLabel(item),
                            if (video != null) '...mais',
                          ].where((s) => s.isNotEmpty).join('  '),
                          style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (item != null)
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => openChannel(context, item.channelUrl, title: item.channel),
                        child: Avatar(item.channelAvatar, size: 40),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => openChannel(context, item.channelUrl, title: item.channel),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.channel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                              if (video != null && video.subscribers >= 0)
                                Text(subscribersLabel(video.subscribers), style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ),
                      SubscribeButton(url: item.channelUrl, title: item.channel, avatar: item.channelAvatar),
                    ],
                  ),
                const SizedBox(height: 12),
                if (item != null) _Actions(item: item, likes: video?.likes ?? -1, live: _isLive, onAsk: _openAsk),
                const SizedBox(height: 12),
                if (_isLive && _live != null)
                  _LiveChatCard(session: _live!)
                else if (video != null)
                  _CommentsCard(url: item!.url),
                if (video == null && _error == null) const LinearProgressIndicator(minHeight: 2),
                if (_error != null && video == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Detalhes indisponíveis: $_error', style: TextStyle(color: colors.error, fontSize: 12)),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        if (video != null && related) SliverList.list(children: _nextRows()),
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }

  void _description(BuildContext context, YtVideo video) {
    final colors = Theme.of(context).colorScheme;
    // Same clean-up as comments (the iOS catalog may still send HTML).
    final text = plainComment(video.description);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            Text(video.item.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Stat(compactCount(video.likes), 'Curtidas'),
                _Stat(compactCount(video.item.views), 'Visualizações'),
                _Stat(uploadedLabel(video.item), 'Publicado'),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: colors.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
              child: SelectableText(text.isEmpty ? 'Sem descrição.' : text),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label);
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(value.isEmpty ? '–' : value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ],
  );
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.item, required this.likes, required this.onAsk, this.live = false});
  final YtItem item;
  final int likes;
  final bool live;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioOnly = ref.watch(audioOnlyProvider);
    Widget pill(IconData icon, String label, VoidCallback? onTap, {bool active = false}) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: active ? UT.text : UT.surface2,
          textStyle: TextStyle(color: active ? UT.bg : UT.text),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: active ? UT.bg : UT.text),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: active ? UT.bg : UT.text)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final track = item.toTrack();
    final liked = ref.watch(likedProvider).any((i) => i.url == item.url);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          pill(
            liked ? Icons.thumb_up : Icons.thumb_up_outlined,
            likes >= 0 ? compactCount(likes + (liked ? 1 : 0)) : 'Curtir',
            () {
              HapticFeedback.lightImpact();
              ref.read(likedProvider.notifier).toggle(item);
            },
            active: liked,
          ),
          AskPill(onTap: onAsk),
          pill(Icons.bookmark_add_outlined, 'Salvar', () => showAddToPlaylist(context, item)),
          pill(Icons.queue_music, 'Fila', () => showQueueSheet(context)),
          if (UltratubeDownloads.supported && !live)
            pill(Icons.download_outlined, 'Baixar', () => showDownloadOptions(context, track)),
          pill(
            audioOnly ? Icons.headphones : Icons.headphones_outlined,
            'Só áudio',
            () => toggleAudioOnly(context, ref),
            active: audioOnly,
          ),
          pill(Icons.share_outlined, 'Compartilhar', () {
            Clipboard.setData(ClipboardData(text: 'https://youtu.be/${item.videoId}'));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copiado')));
          }),
        ],
      ),
    );
  }
}

/// "1,2 mil assistindo agora  •  AO VIVO" under the title of a live.
class _LiveMetaLine extends ConsumerWidget {
  const _LiveMetaLine({required this.session, required this.more});
  final LiveSession session;
  final bool more;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(liveChatPrefsProvider.select((p) => p.showViewers));
    final style = TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Row(
      children: [
        const Icon(Icons.circle, size: 8, color: UT.red),
        const SizedBox(width: 5),
        const Text('AO VIVO', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: UT.red, letterSpacing: 0.3)),
        if (show)
          ValueListenableBuilder<int>(
            valueListenable: session.viewers,
            builder: (_, n, _) => n < 0 ? const SizedBox.shrink() : Text('  ·  ${compactCount(n)} assistindo agora', style: style),
          ),
        if (more) Text('  ...mais', style: style),
      ],
    );
  }
}

/// Live chat entry under the video: newest lines, overlay toggle and a tap
/// target that opens the full chat.
class _LiveChatCard extends ConsumerWidget {
  const _LiveChatCard({required this.session});
  final LiveSession session;

  void _openChat(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: UT.surface1,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, controller) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(UT.s5, 0, UT.s5, UT.s2),
            child: Row(children: [Text('Chat ao vivo', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))]),
          ),
          const Divider(height: 1, color: UT.line),
          Expanded(child: LiveChatPanel(feed: session.chat)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(liveChatPrefsProvider);
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openChat(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Chat ao vivo', style: TextStyle(fontWeight: FontWeight.w700))),
                  IconButton(
                    tooltip: prefs.overlay ? 'Tirar chat de cima do vídeo' : 'Mostrar chat sobre o vídeo',
                    icon: Icon(prefs.overlay ? Icons.picture_in_picture_alt_rounded : Icons.picture_in_picture_alt_outlined),
                    color: prefs.overlay ? UT.text : UT.text2,
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      ref.read(liveChatPrefsProvider.notifier).toggleOverlay();
                    },
                  ),
                  IconButton(
                    tooltip: 'Ajustes do chat',
                    icon: const Icon(Icons.tune_rounded),
                    color: UT.text2,
                    onPressed: () => showLiveChatSettings(context),
                  ),
                ],
              ),
              ListenableBuilder(
                listenable: session.chat,
                builder: (context, _) {
                  final feed = session.chat;
                  final last = feed.messages.reversed.take(3).toList().reversed.toList();
                  if (last.isEmpty) {
                    return Text(
                      feed.error ?? (feed.connected ? 'Aguardando mensagens…' : 'Conectando ao chat…'),
                      style: TextStyle(color: colors.onSurfaceVariant),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final m in last)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text.rich(chatLineSpan(m, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentsCard extends StatefulWidget {
  const _CommentsCard({required this.url});
  final String url;
  @override
  State<_CommentsCard> createState() => _CommentsCardState();
}

class _CommentsCardState extends State<_CommentsCard> {
  static const _catalog = UltratubeCatalog();
  List<YtComment> _comments = const [];
  String? _next;
  bool _disabled = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _catalog.comments(widget.url).then((r) {
      if (!mounted) return;
      setState(() {
        _comments = r.$1;
        _next = r.$2;
        _disabled = r.$3;
        _loaded = true;
      });
    }).catchError((_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final first = _comments.isNotEmpty ? _comments.first : null;
    return Material(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _comments.isEmpty ? null : () => _open(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Comentários', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (!_loaded)
                const LinearProgressIndicator(minHeight: 2)
              else if (_disabled)
                Text('Comentários desativados', style: TextStyle(color: colors.onSurfaceVariant))
              else if (first == null)
                Text('Nenhum comentário', style: TextStyle(color: colors.onSurfaceVariant))
              else
                Row(
                  children: [
                    Avatar(first.avatar, size: 24),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_plain(first.text), maxLines: 2, overflow: TextOverflow.ellipsis)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => StatefulBuilder(
      builder: (context, setSheet) {
        var loading = false;
        Future<void> more() async {
          if (_next == null || loading) return;
          loading = true;
          try {
            final r = await _catalog.moreComments(_next!);
            _comments = [..._comments, ...r.$1];
            _next = r.$2;
            setSheet(() {});
          } catch (_) {
            _next = null;
          }
          loading = false;
        }

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          builder: (_, controller) => NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.extentAfter < 600) more();
              return false;
            },
            child: ListView.builder(
              controller: controller,
              itemCount: _comments.length + 1,
              itemBuilder: (context, i) {
                if (i == _comments.length) {
                  return _next == null ? const SizedBox(height: 32) : const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                }
                final c = _comments[i];
                final colors = Theme.of(context).colorScheme;
                return ListTile(
                  leading: Avatar(c.avatar, size: 32),
                  title: Text(
                    [c.author, c.uploaded].where((s) => s.isNotEmpty).join(' · '),
                    style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (c.pinned) Text('Fixado', style: TextStyle(fontSize: 11, color: colors.primary)),
                      const SizedBox(height: 2),
                      Text(_plain(c.text), style: TextStyle(color: colors.onSurface, fontSize: 14)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.thumb_up_outlined, size: 14),
                          const SizedBox(width: 4),
                          Text(c.likes > 0 ? compactCount(c.likes) : '', style: const TextStyle(fontSize: 12)),
                          if (c.hearted) ...[const SizedBox(width: 12), Icon(Icons.favorite, size: 14, color: colors.primary)],
                          if (c.replies > 0) ...[const SizedBox(width: 12), Text('${c.replies} respostas', style: const TextStyle(fontSize: 12))],
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    ),
  );

  static String _plain(String html) => html
      .replaceAll(RegExp(r'<br\s*/?>'), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}

/// Transparent hole over the shared video surface plus YouTube-like controls.
class _VideoSlot extends ConsumerStatefulWidget {
  const _VideoSlot({
    required this.slotKey,
    required this.item,
    required this.fullscreen,
    required this.onFullscreen,
    this.live = false,
    this.session,
  });
  final GlobalKey slotKey;
  final YtItem? item;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final bool live;
  final LiveSession? session;
  @override
  ConsumerState<_VideoSlot> createState() => _VideoSlotState();
}

class _VideoSlotState extends ConsumerState<_VideoSlot> {
  bool _controls = true;
  Timer? _hide;
  double? _drag;
  String? _flash;

  /// Vertical drag on the picture: pulling down past [_menuPull] (or a quick
  /// flick) opens the video menu (options, queue, playlist).
  double _pull = 0;
  static const _menuPull = 56.0;

  void _openMenu([VideoMenuTab tab = VideoMenuTab.options]) =>
      showVideoMenu(context, item: widget.item, live: widget.live, initial: tab);

  void _pullEnd(DragEndDetails d) {
    final open = _pull > _menuPull || (d.primaryVelocity ?? 0) > 600;
    setState(() => _pull = 0);
    if (open) _openMenu();
  }

  /// Paused during a live: playback resumes behind the live edge.
  bool _behind = false;

  void _goLive() {
    setState(() => _behind = false);
    // Reopening the HLS manifest starts again at the live edge.
    ref.read(playerProvider.notifier).retryLoad();
    _show();
  }

  @override
  void initState() {
    super.initState();
    _armHide();
  }

  void _show() {
    setState(() => _controls = true);
    _armHide();
  }

  /// Hides the controls after 3 s of playback, like YouTube. Paused or
  /// still-loading videos keep them on screen.
  void _armHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && ref.read(playerProvider).isPlaying) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    if (_controls) {
      _hide?.cancel();
      setState(() => _controls = false);
    } else {
      _show();
    }
  }

  void _seekBy(int seconds) {
    if (widget.live) return;
    final s = ref.read(playerProvider);
    final target = s.position + Duration(seconds: seconds);
    ref.read(playerProvider.notifier).seekTo(target < Duration.zero ? Duration.zero : (target > s.duration ? s.duration : target));
    setState(() => _flash = seconds > 0 ? '+${seconds}s' : '${seconds}s');
    Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Playback starting (or resuming elsewhere) arms the auto-hide; pausing
    // brings the controls back.
    ref.listen(playerProvider.select((s) => s.isPlaying), (was, playing) {
      if (!mounted) return;
      if (playing && _controls) _armHide();
      if (!playing && was == true && !_controls) _show();
    });
    final state = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final autoplay = ref.watch(ultratubeAutoplayProvider);
    final chatPrefs = ref.watch(liveChatPrefsProvider);
    final audioOnly = !ref.watch(settingsProvider.select((s) => s.showVideo));
    final live = widget.live;
    // Lives have no fixed duration, so "started" can't wait for one.
    final started = state.currentTrack?.youtubeVideoId == widget.item?.videoId &&
        (state.duration > Duration.zero || state.position > Duration.zero || state.isPlaying);
    final session = widget.session;
    final showOverlay = live && session != null && chatPrefs.overlay && started;
    final loading = state.isLoadingVideo || !started;
    final duration = state.duration.inMilliseconds.toDouble();
    final position = (_drag ?? state.position.inMilliseconds.toDouble()).clamp(0.0, duration <= 0 ? 1.0 : duration);
    String t(Duration d) => durationLabel(d.inSeconds).isEmpty ? '0:00' : durationLabel(d.inSeconds);

    return MouseRegion(
      // Desktop: moving the mouse over the video brings the controls back.
      onHover: (_) => _controls ? _armHide() : _show(),
      child: Container(
      key: widget.slotKey,
      // Transparent: the shared video surface renders underneath.
      color: started ? Colors.transparent : Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!started && widget.item != null && widget.item!.bestCover.isNotEmpty)
            Opacity(opacity: 0.6, child: NetImage(widget.item!.bestCover)),
          // Audio only: the cover stands in for the picture.
          if (started && audioOnly) ...[
            if (widget.item != null && widget.item!.bestCover.isNotEmpty) NetImage(widget.item!.bestCover),
            const Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.all(10),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.all(Radius.circular(12))),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.headphones, size: 14, color: Colors.white),
                        SizedBox(width: 4),
                        Text('Só áudio', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (loading && state.loadError == null) const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (state.loadError != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white),
                    const SizedBox(height: 8),
                    const Text('Falha ao reproduzir', style: TextStyle(color: Colors.white)),
                    TextButton(onPressed: notifier.retryLoad, child: const Text('Tentar de novo')),
                  ],
                ),
              ),
            ),
          // Dim layer behind the controls. It never takes touches, so a tap
          // anywhere outside a button reaches the gesture layer below and
          // hides the controls (before, this layer swallowed every tap).
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _controls ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: const ColoredBox(color: Colors.black38),
            ),
          ),
          // Gestures: tap toggles controls, double-tap sides seeks ±10 s,
          // dragging down opens the video menu.
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (_) => _pull = 0,
            onVerticalDragUpdate: (d) => setState(() => _pull = (_pull + d.delta.dy).clamp(0.0, _menuPull * 2)),
            onVerticalDragEnd: _pullEnd,
            onVerticalDragCancel: () => setState(() => _pull = 0),
            child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleControls,
                  // No seeking in a live: a plain tap then reacts instantly.
                  onDoubleTap: live ? null : () => _seekBy(-10),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleControls,
                  onDoubleTap: live ? null : () => _seekBy(10),
                ),
              ),
            ],
          ),
          ),
          // Pull feedback: a chip slides in from the top while dragging.
          if (_pull > 0)
            IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: Transform.translate(
                  offset: Offset(0, (_pull / 2).clamp(0.0, _menuPull) - 8),
                  child: Opacity(
                    opacity: (_pull / _menuPull).clamp(0.0, 1.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_pull > _menuPull ? Icons.expand_more : Icons.drag_handle, size: 16, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(
                            _pull > _menuPull ? 'Solte para abrir' : 'Opções · Fila · Playlist',
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Transparent live chat over the picture (toggle + opacity in the
          // chat settings). Moves up while the controls are showing.
          if (showOverlay)
            AnimatedPositioned(
              duration: UT.motion,
              curve: UT.curve,
              left: 10,
              right: 10,
              top: 44,
              bottom: _controls ? 64 : 10,
              child: LiveChatOverlay(
                feed: session.chat,
                maxLines: widget.fullscreen ? 9 : 4,
                widthFactor: widget.fullscreen ? 0.42 : 0.7,
              ),
            ),
          if (_flash != null)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: Text(_flash!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          IgnorePointer(
            ignoring: !_controls,
            child: AnimatedOpacity(
              opacity: _controls ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: SizedBox.expand(
                child: Stack(
                  children: [
                    Positioned(
                      top: 4,
                      left: 4,
                      child: IconButton(
                        tooltip: 'Minimizar',
                        color: Colors.white,
                        icon: const Icon(Icons.keyboard_arrow_down),
                        onPressed: () => widget.fullscreen ? widget.onFullscreen() : context.pop(),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 52,
                      child: IconButton(
                        tooltip: autoplay ? 'Reprodução automática ativada' : 'Reprodução automática desativada',
                        icon: Icon(autoplay ? Icons.play_circle : Icons.pause_circle_outline, color: autoplay ? Colors.white : Colors.white54),
                        onPressed: () {
                          ref.read(ultratubeAutoplayProvider.notifier).set(!autoplay);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(autoplay ? 'Reprodução automática desativada' : 'Reprodução automática ativada')),
                          );
                        },
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const PipButton(),
                          IconButton(
                            tooltip: 'Opções do vídeo (ou arraste para baixo)',
                            icon: const Icon(Icons.settings_outlined, color: Colors.white),
                            onPressed: _openMenu,
                          ),
                        ],
                      ),
                    ),
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            iconSize: 34,
                            color: Colors.white,
                            tooltip: 'Anterior',
                            icon: const Icon(Icons.skip_previous_rounded),
                            onPressed: () {
                              notifier.skipPrevious();
                              _show();
                            },
                          ),
                          const SizedBox(width: 24),
                          IconButton(
                            iconSize: 52,
                            color: Colors.white,
                            tooltip: state.isPlaying ? 'Pausar' : 'Reproduzir',
                            icon: Icon(state.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                            onPressed: () {
                              if (live && state.isPlaying) setState(() => _behind = true);
                              notifier.togglePlay();
                              _show();
                            },
                          ),
                          const SizedBox(width: 24),
                          IconButton(
                            iconSize: 34,
                            color: Colors.white,
                            tooltip: 'Próximo',
                            icon: const Icon(Icons.skip_next_rounded),
                            onPressed: () {
                              notifier.skipNext();
                              _show();
                            },
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 4,
                      bottom: 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              if (live) ...[
                                LiveBadge(behind: _behind, onTap: _behind ? _goLive : null),
                                if (session != null) ...[
                                  const SizedBox(width: 6),
                                  ViewerCountChip(viewers: session.viewers),
                                ],
                              ] else
                                Text(
                                  '${t(Duration(milliseconds: position.round()))} / ${t(state.duration)}',
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              const Spacer(),
                              if (live && session != null) ...[
                                IconButton(
                                  color: Colors.white,
                                  tooltip: chatPrefs.overlay ? 'Ocultar chat do vídeo' : 'Mostrar chat no vídeo',
                                  icon: Icon(chatPrefs.overlay ? Icons.chat_rounded : Icons.chat_outlined),
                                  onPressed: () {
                                    HapticFeedback.selectionClick();
                                    ref.read(liveChatPrefsProvider.notifier).toggleOverlay();
                                    _show();
                                  },
                                ),
                                IconButton(
                                  color: Colors.white,
                                  tooltip: 'Ajustes do chat ao vivo',
                                  icon: const Icon(Icons.tune_rounded),
                                  onPressed: () => showLiveChatSettings(context),
                                ),
                              ],
                              IconButton(
                                color: Colors.white,
                                tooltip: widget.fullscreen ? 'Sair da tela cheia' : 'Tela cheia',
                                icon: Icon(widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                                onPressed: widget.onFullscreen,
                              ),
                            ],
                          ),
                          if (live)
                            // Full red bar: a live has no seekable timeline.
                            Container(height: 3, margin: const EdgeInsets.fromLTRB(0, 4, 8, 10), color: UT.red)
                          else
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                              activeTrackColor: const Color(0xFFFF0033),
                              thumbColor: const Color(0xFFFF0033),
                              inactiveTrackColor: Colors.white30,
                              secondaryActiveTrackColor: Colors.white54,
                            ),
                            child: SizedBox(
                              height: 24,
                              child: Slider(
                                value: position.toDouble(),
                                max: duration <= 0 ? 1 : duration,
                                secondaryTrackValue: state.buffered.inMilliseconds.toDouble().clamp(0.0, duration <= 0 ? 1.0 : duration),
                                onChanged: duration <= 0 ? null : (v) => setState(() => _drag = v),
                                onChangeEnd: (v) {
                                  notifier.seekTo(Duration(milliseconds: v.round()));
                                  setState(() => _drag = null);
                                  _show();
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}

/// Title of a list section on the watch page, optionally with a shortcut
/// to the full queue.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.detail, this.onQueue});
  final String title;
  final String? detail;
  final VoidCallback? onQueue;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(UT.s3, UT.s2, UT.s2, UT.s1),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          if (detail != null) ...[
            const SizedBox(width: UT.s2),
            Expanded(
              child: Text(
                detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: UT.text2, fontSize: 12.5),
              ),
            ),
          ] else
            const Spacer(),
          if (onQueue != null)
            TextButton.icon(
              onPressed: onQueue,
              icon: const Icon(Icons.queue_music, size: 18),
              label: const Text('Fila'),
            ),
        ],
      ),
    ),
  );
}
