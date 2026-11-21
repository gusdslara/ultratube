import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/ultratube_catalog.dart';
import '../../core/downloads/ultratube_downloads.dart';
import '../../core/playback/playback_providers.dart';
import '../../core/playback/ultratube_playback_controller.dart' show UltratubeResolveCache;
import '../../core/player/player_provider.dart';
import '../../core/player/video_layout_provider.dart';
import '../../core/services/settings_provider.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/ultratube/feeds.dart';
import '../../core/ultratube/ultratube_store.dart';
import '../../core/ultratube/youtube_account.dart';
import '../ultratube/comments_sheet.dart';
import '../ultratube/yt_widgets.dart';

/// Endless vertical Shorts player. Opens on [seed] when a Short was tapped,
/// otherwise builds a feed from what the viewer watches.
class ShortsScreen extends ConsumerStatefulWidget {
  const ShortsScreen({super.key, this.seed = const []});
  final List<YtItem> seed;
  @override
  ConsumerState<ShortsScreen> createState() => _ShortsScreenState();
}

/// Set by the player once extraction/stream retries are exhausted.
const _connectionLost = 'error:connection_lost';

class _ShortsScreenState extends ConsumerState<ShortsScreen> with WidgetsBindingObserver {
  final _pages = PageController();
  final _slot = GlobalKey();
  final List<YtItem> _items = [];
  final Set<String> _seen = {};
  int _index = 0;
  int _emptyLoads = 0;
  late final ShortsFeed _feed;

  /// Title, channel and counters fetched per Short (YouTube's feed only
  /// names the first item of a page).
  final Map<String, ShortInfo> _info = {};
  final Set<String> _infoRequested = {};
  Timer? _stall;
  final Set<String> _logged = {};
  final Set<String> _blockedChannels = {};
  bool _advanceWhenLoaded = false;
  bool _loading = false;
  String? _error;
  late PlaybackController _playback;
  late VideoLayoutNotifier _layout;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _playback = ref.read(playbackControllerProvider);
    _layout = ref.read(videoLayoutProvider.notifier);
    _feed = ref.read(shortsFeedProvider)();
    _add(widget.seed);
    if (_items.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _play(0));
    }
    _loadMore(autoplay: _items.isEmpty);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stall?.cancel();
    _pages.dispose();
    unawaited(_playback.pause());
    Future<void>.microtask(_layout.clear);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _measure();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(_playback.pause());
  }

  void _add(Iterable<YtItem> items) {
    for (final item in items) {
      if (_blockedChannels.contains(item.channelUrl)) continue;
      final id = item.videoId;
      if (id == null || !_seen.add(id)) continue;
      // Shorts resolve through the quicker app client (see Catalog.resolve).
      UltratubeCatalog.fastIds.add(id);
      _items.add(item);
    }
  }

  /// Gets the next Shorts ready while the current one plays: stream URLs
  /// resolved, cover in the image cache, title and counters loaded. Swiping
  /// then only has to open the stream.
  void _prepare(int from) {
    final settings = ref.read(settingsProvider);
    final maxHeight = ref.read(videoQualityProvider);
    for (var i = from; i <= from + 2 && i < _items.length; i++) {
      final item = _items[i];
      final id = item.videoId!;
      if (i != from) {
        UltratubeResolveCache.warm(id, video: settings.showVideo, maxHeight: maxHeight);
        if (item.cover.startsWith('http')) {
          unawaited(precacheImage(NetworkImage(item.cover), context, onError: (_, _) {}));
        }
      }
      _loadInfo(item);
    }
  }

  Future<void> _loadInfo(YtItem item) async {
    final id = item.videoId!;
    if (!_infoRequested.add(id)) return;
    try {
      final info = await YoutubeAccountNotifier.api.shortInfo(id);
      if (!mounted) return;
      final at = _items.indexWhere((i) => i.videoId == id);
      setState(() {
        _info[id] = info;
        // Fill what the feed left blank; never overwrite what it did say.
        if (at >= 0) {
          final old = _items[at];
          _items[at] = YtItem.fromJson({
            ...old.toJson(),
            'type': 'video',
            if (old.title.isEmpty) 'title': info.title,
            if (old.channel.isEmpty) ...{'channel': info.channel, 'artist': info.channel},
            if (old.channelUrl.isEmpty) 'channelUrl': info.channelUrl,
            if (old.channelAvatar.isEmpty) 'channelAvatar': info.channelAvatar,
          });
          // Already in the history without a title: store the complete entry.
          if (_logged.contains(id) && old.title.isEmpty) ref.read(historyProvider.notifier).add(_items[at]);
        }
      });
    } catch (error) {
      // Unsupported platform or a network hiccup: the Short still plays,
      // with whatever the feed said about it.
      debugPrint('Ultratube: dados do Short $id indisponíveis: $error');
    }
  }

  Future<void> _loadMore({bool autoplay = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final found = await _feed.next();
      if (!mounted) return;
      final before = _items.length;
      setState(() => _add(found));
      if (autoplay && before == 0 && _items.isNotEmpty) {
        _play(0);
      } else if (_items.length > before) {
        _prepare(_index); // the new arrivals may be the very next Shorts
      }
      if (_advanceWhenLoaded && _index + 1 < _items.length) {
        _advanceWhenLoaded = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pages.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
        });
      }
      if (_items.length == before) {
        if (++_emptyLoads < 8) {
          _loading = false;
          return await _loadMore(autoplay: autoplay);
        }
      } else {
        _emptyLoads = 0;
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _slot.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final position = box.localToGlobal(Offset.zero);
      final old = ref.read(videoLayoutProvider);
      if (old.size != box.size || old.position != position || !old.isVisible) {
        _layout.updateLayout(box.size, position, isVisible: true, label: 'ultratube_shorts');
      }
    });
  }

  Future<void> _play(int index) async {
    if (index < 0 || index >= _items.length) return;
    setState(() => _index = index);
    if (index >= _items.length - 4) _loadMore();
    await ref.read(settingsProvider.notifier).setPlayerView(PlayerView.video);
    if (!mounted) return;
    _measure();
    final item = _items[index];
    // Watchdog: a Short that never starts is skipped. Extraction and stream
    // errors are retried below this screen first, so allow for that; a
    // connection failure shows a retry instead (see the loadError listener).
    _stall?.cancel();
    _stall = Timer(const Duration(seconds: 30), () {
      final s = ref.read(playerProvider);
      if (!mounted || _index != index || s.loadError == _connectionLost) return;
      if (_logged.contains(item.videoId)) return; // it played (and loops back to 0)
      if (s.currentTrack?.youtubeVideoId != item.videoId || s.position == Duration.zero) {
        _skipUnplayable(item, block: false);
      }
    });
    // The player bar and notification need a name even before the Short's
    // own title arrives.
    final track = item.title.isEmpty ? item.toTrack().copyWith(name: 'Shorts') : item.toTrack();
    final playing = ref.read(playerProvider.notifier).playTrack(track, queue: [track]);
    _prepare(index);
    await playing;
    if (mounted) _measure();
  }

  /// [block]: the Short itself can never play (private, kids-only, region,
  /// age). Only then is its channel dropped; a slow or failed load is not
  /// the channel's fault.
  void _skipUnplayable(YtItem item, {bool block = true}) {
    // Never let a restricted Short shape future recommendations, and drop
    // the rest of that channel's queued Shorts (restrictions are per channel).
    if (block) {
      for (final h in ref.read(historyProvider).where((h) => h.channelUrl.isNotEmpty && h.channelUrl == item.channelUrl).toList()) {
        ref.read(historyProvider.notifier).remove(h);
      }
      ref.read(historyProvider.notifier).remove(item);
    }
    if (block && item.channelUrl.isNotEmpty) {
      _blockedChannels.add(item.channelUrl);
      setState(() {
        final keep = _items.take(_index + 1).toList();
        final rest = _items.skip(_index + 1).where((i) => i.channelUrl != item.channelUrl);
        _items
          ..clear()
          ..addAll([...keep, ...rest]);
      });
      if (_items.length - _index < 4) _loadMore();
    }
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted || _items.elementAtOrNull(_index)?.videoId != item.videoId) return;
      if (_index + 1 < _items.length) {
        _pages.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
      } else {
        // Nothing queued yet: advance as soon as the next batch arrives.
        _advanceWhenLoaded = true;
        _loadMore();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    // A blocked/unavailable Short skips ahead instead of stalling the feed.
    // A lost connection would fail the next Short too: offer a retry instead.
    ref.listen(playerProvider.select((s) => s.loadError), (prev, next) {
      final current = _items.elementAtOrNull(_index);
      if (next == null || current == null || next == _connectionLost) return;
      if (ref.read(playerProvider).currentTrack?.youtubeVideoId != current.videoId) return;
      _skipUnplayable(current, block: next.startsWith('unavailable'));
    });
    // Loop the current Short like YouTube does; log it once it really plays.
    ref.listen(playerProvider.select((s) => s.position), (prev, next) {
      final s = ref.read(playerProvider);
      final current = _items.elementAtOrNull(_index);
      if (current != null && next > const Duration(seconds: 1) && s.currentTrack?.youtubeVideoId == current.videoId && _logged.add(current.videoId!)) {
        ref.read(historyProvider.notifier).add(current);
      }
      if (s.duration > Duration.zero && next >= s.duration - const Duration(milliseconds: 300) && s.currentTrack?.youtubeVideoId == _items.elementAtOrNull(_index)?.videoId) {
        ref.read(playerProvider.notifier).seekTo(Duration.zero);
      }
    });
    _measure();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            if (_items.isEmpty)
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: _error != null
                    ? ErrorRetry(message: 'Não foi possível carregar Shorts.', onRetry: () => _loadMore(autoplay: true))
                    : const CircularProgressIndicator(color: Colors.white),
              )
            else
              PageView.builder(
                controller: _pages,
                scrollDirection: Axis.vertical,
                itemCount: _items.length,
                onPageChanged: (i) => unawaited(_play(i)),
                itemBuilder: (context, i) {
                  final item = _items[i];
                  final current = i == _index;
                  final started = current && player.currentTrack?.youtubeVideoId == item.videoId && player.duration > Duration.zero;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        key: current ? _slot : null,
                        color: started ? Colors.transparent : Colors.black,
                        child: started ? null : NetImage(item.cover, fit: BoxFit.cover),
                      ),
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => ref.read(playerProvider.notifier).togglePlay(),
                      ),
                      if (current && !player.isPlaying && started)
                        const IgnorePointer(child: Center(child: Icon(Icons.play_arrow_rounded, size: 84, color: Colors.white70))),
                      if (current && !started && player.loadError == null)
                        const Center(child: CircularProgressIndicator(color: Colors.white)),
                      if (current && player.loadError == _connectionLost)
                        Center(
                          child: ErrorRetry(
                            message: 'Sem conexão com o YouTube.',
                            onRetry: () => unawaited(_play(_index)),
                          ),
                        ),
                      _Overlay(item: item, info: _info[item.videoId]),
                    ],
                  );
                },
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    IconButton(
                      color: Colors.white,
                      tooltip: 'Voltar',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
                    ),
                    const Text('Shorts', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    IconButton(
                      color: Colors.white,
                      tooltip: 'Buscar Shorts',
                      icon: const Icon(Icons.search),
                      onPressed: () => context.push('/search?kind=shorts'),
                    ),
                  ],
                ),
              ),
            ),
            if (_items.isNotEmpty && player.position > Duration.zero && player.duration > Duration.zero)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  value: (player.position.inMilliseconds / player.duration.inMilliseconds).clamp(0.0, 1.0),
                  color: Colors.white,
                  backgroundColor: Colors.white24,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Overlay extends ConsumerWidget {
  const _Overlay({required this.item, this.info});
  final YtItem item;
  final ShortInfo? info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const shadow = [Shadow(blurRadius: 6, color: Colors.black54)];
    final liked = ref.watch(likedProvider.select((l) => l.any((i) => i.url == item.url)));
    final likes = info?.likes ?? '';
    final comments = info?.comments ?? '';
    Widget action(IconData icon, String label, VoidCallback onTap, {Color color = Colors.white, String? tooltip}) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Tooltip(
        message: tooltip ?? label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Column(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
                child: Icon(icon, color: color),
              ),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, shadows: shadow)),
            ],
          ),
        ),
      ),
    );

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black54],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 40, 8, 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () => openChannel(context, item.channelUrl, title: item.channel),
                            child: Avatar(item.channelAvatar, size: 32),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              item.channel.isEmpty ? item.artist : '@${item.channel}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, shadows: shadow),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (item.channelUrl.isNotEmpty)
                            SubscribeButton(url: item.channelUrl, title: item.channel, avatar: item.channelAvatar, dense: true),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 14, shadows: shadow),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    action(
                      liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                      likes.isNotEmpty ? likes : 'Curtir',
                      () {
                        HapticFeedback.selectionClick();
                        ref.read(likedProvider.notifier).toggle(item);
                      },
                      color: liked ? UT.red : Colors.white,
                      tooltip: liked ? 'Remover dos vídeos curtidos' : 'Curtir',
                    ),
                    action(
                      Icons.mode_comment_outlined,
                      comments.isNotEmpty ? comments : 'Comentar',
                      () => showCommentsSheet(
                        context,
                        url: 'https://www.youtube.com/watch?v=${item.videoId}',
                        countLabel: comments,
                      ),
                      tooltip: 'Comentários',
                    ),
                    action(Icons.share_outlined, 'Compartilhar', () {
                      Clipboard.setData(ClipboardData(text: 'https://youtube.com/shorts/${item.videoId}'));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copiado')));
                    }),
                    if (UltratubeDownloads.supported)
                      action(Icons.download_outlined, 'Baixar', () => startDownload(item.toTrack(), video: true, maxHeight: 1080)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
