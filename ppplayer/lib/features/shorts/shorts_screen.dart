import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/ultratube_catalog.dart';
import '../../core/downloads/ultratube_downloads.dart';
import '../../core/playback/playback_providers.dart';
import '../../core/player/player_provider.dart';
import '../../core/player/video_layout_provider.dart';
import '../../core/services/settings_provider.dart';
import '../../core/ultratube/feeds.dart';
import '../../core/ultratube/ultratube_store.dart';
import '../ultratube/yt_widgets.dart';

/// Endless vertical Shorts player. Opens on [seed] when a Short was tapped,
/// otherwise builds a feed from what the viewer watches.
class ShortsScreen extends ConsumerStatefulWidget {
  const ShortsScreen({super.key, this.seed = const []});
  final List<YtItem> seed;
  @override
  ConsumerState<ShortsScreen> createState() => _ShortsScreenState();
}

class _ShortsScreenState extends ConsumerState<ShortsScreen> with WidgetsBindingObserver {
  final _pages = PageController();
  final _slot = GlobalKey();
  final List<YtItem> _items = [];
  final Set<String> _seen = {};
  int _index = 0;
  int _discoveryPage = 0;
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
      if (item.videoId != null && _seen.add(item.videoId!)) _items.add(item);
    }
  }

  Future<void> _loadMore({bool autoplay = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final found = await ref.read(shortsDiscoveryProvider)(_discoveryPage++);
      if (!mounted) return;
      final before = _items.length;
      setState(() => _add(found));
      if (autoplay && before == 0 && _items.isNotEmpty) _play(0);
      if (_advanceWhenLoaded && _index + 1 < _items.length) {
        _advanceWhenLoaded = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pages.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
        });
      }
      if (_items.length == before && _discoveryPage < 8) {
        _loading = false;
        return _loadMore(autoplay: autoplay);
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
    // Watchdog: a Short that never starts (blocked, kids-only, region) is skipped.
    _stall?.cancel();
    _stall = Timer(const Duration(seconds: 12), () {
      final s = ref.read(playerProvider);
      if (!mounted || _index != index) return;
      if (s.currentTrack?.youtubeVideoId != item.videoId || s.position == Duration.zero) _skipUnplayable(item);
    });
    final track = item.toTrack();
    await ref.read(playerProvider.notifier).playTrack(track, queue: [track]);
    if (mounted) _measure();
  }

  void _skipUnplayable(YtItem item) {
    // Never let a failed Short shape future recommendations, and drop the
    // rest of that channel's queued Shorts (restrictions are per channel:
    // kids-only, region, age).
    for (final h in ref.read(historyProvider).where((h) => h.channelUrl.isNotEmpty && h.channelUrl == item.channelUrl).toList()) {
      ref.read(historyProvider.notifier).remove(h);
    }
    ref.read(historyProvider.notifier).remove(item);
    if (item.channelUrl.isNotEmpty) {
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
    ref.listen(playerProvider.select((s) => s.loadError), (prev, next) {
      final current = _items.elementAtOrNull(_index);
      if (next == null || current == null) return;
      if (ref.read(playerProvider).currentTrack?.youtubeVideoId != current.videoId) return;
      _skipUnplayable(current);
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
                      _Overlay(item: item),
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

class _Overlay extends StatelessWidget {
  const _Overlay({required this.item});
  final YtItem item;

  @override
  Widget build(BuildContext context) {
    const shadow = [Shadow(blurRadius: 6, color: Colors.black54)];
    Widget action(IconData icon, String label, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
              child: Icon(icon, color: Colors.white),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, shadows: shadow)),
          ],
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
                    action(Icons.thumb_up_outlined, item.views >= 0 ? compactCount(item.views) : 'Curtir', () {}),
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
