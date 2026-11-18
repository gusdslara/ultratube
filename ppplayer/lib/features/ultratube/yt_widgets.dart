import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/yt_models.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/ultratube/ultratube_store.dart';
import '../downloads/track_actions_button.dart';

// ---------------------------------------------------------------- formatting

/// "1,2 mi", "350 mil", "999".
String compactCount(int n) {
  if (n < 0) return '';
  String fmt(double v) {
    final s = v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s.replaceAll('.', ',');
  }

  if (n >= 1000000000) return '${fmt(n / 1e9)} bi';
  if (n >= 1000000) return '${fmt(n / 1e6)} mi';
  if (n >= 1000) return '${fmt(n / 1e3)} mil';
  return '$n';
}

String viewsLabel(int views, {bool live = false}) {
  if (views < 0) return '';
  if (live) return '${compactCount(views)} assistindo';
  return views == 1 ? '1 visualização' : '${compactCount(views)} de visualizações';
}

String subscribersLabel(int n) => n < 0 ? '' : '${compactCount(n)} ${n == 1 ? 'inscrito' : 'inscritos'}';

String durationLabel(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Relative upload time, preferring the exact timestamp when present.
String uploadedLabel(YtItem item) {
  if (item.uploadedAt > 0) {
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(item.uploadedAt));
    if (diff.inMinutes < 60) return 'há ${diff.inMinutes.clamp(1, 59)} min';
    if (diff.inHours < 24) return 'há ${diff.inHours} h';
    if (diff.inDays < 7) return 'há ${diff.inDays} ${diff.inDays == 1 ? 'dia' : 'dias'}';
    if (diff.inDays < 30) {
      final w = diff.inDays ~/ 7;
      return 'há $w ${w == 1 ? 'semana' : 'semanas'}';
    }
    if (diff.inDays < 365) {
      final mo = diff.inDays ~/ 30;
      return 'há $mo ${mo == 1 ? 'mês' : 'meses'}';
    }
    final y = diff.inDays ~/ 365;
    return 'há $y ${y == 1 ? 'ano' : 'anos'}';
  }
  return item.uploaded;
}

String metaLine(YtItem item, {bool withChannel = true}) {
  if (item.kind == YtKind.playlist) {
    return [
      if (withChannel && item.channel.isNotEmpty) item.channel,
      'Playlist',
      if (item.videos > 0) '${item.videos} vídeos',
    ].join(' · ');
  }
  return [
    if (withChannel && item.channel.isNotEmpty) item.channel,
    viewsLabel(item.views, live: item.live),
    if (!item.live) uploadedLabel(item),
  ].where((s) => s.isNotEmpty).join(' · ');
}

// ---------------------------------------------------------------- navigation

/// Opens any catalog item the way YouTube does.
void openItem(BuildContext context, YtItem item, {List<YtItem>? shortsFeed}) {
  HapticFeedback.selectionClick();
  switch (item.kind) {
    case YtKind.channel:
      openChannel(context, item.url, title: item.title);
    case YtKind.playlist:
      context.push('/ytplaylist?url=${Uri.encodeComponent(item.url)}');
    case YtKind.video:
      final id = item.videoId;
      if (id == null) return;
      if (item.shorts) {
        context.push('/shorts', extra: [item, ...?shortsFeed?.where((s) => s.url != item.url)]);
      } else {
        context.push('/watch?v=$id', extra: item);
      }
  }
}

void openChannel(BuildContext context, String url, {String title = ''}) {
  if (url.isEmpty) return;
  context.push('/channel?url=${Uri.encodeComponent(url)}', extra: title);
}

// ---------------------------------------------------------------- building blocks

class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.icon = Icons.smart_display_outlined, this.cacheWidth});
  final String url;
  final BoxFit fit;
  final IconData icon;

  /// Decode width in logical px (scaled by DPR) to cap memory on big lists.
  final double? cacheWidth;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: UT.surface2,
      child: Center(child: Icon(icon, color: UT.text3)),
    );
    if (url.isEmpty) return placeholder;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (url.startsWith('/') || url.startsWith('file:')) {
      final path = url.startsWith('file:') ? Uri.parse(url).toFilePath() : url;
      return Image.file(File(path), fit: fit, errorBuilder: (_, _, _) => placeholder);
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      memCacheWidth: cacheWidth == null ? null : (cacheWidth! * dpr).round(),
      fadeInDuration: const Duration(milliseconds: 180),
      placeholder: (_, _) => const ColoredBox(color: UT.surface2),
      errorWidget: (_, _, _) => placeholder,
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar(this.url, {super.key, this.size = 36});
  final String url;
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ClipOval(child: NetImage(url, icon: Icons.person, cacheWidth: size)),
  );
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.color, this.icon});
  final String text;
  final Color? color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(color: color ?? const Color(0xCC000000), borderRadius: BorderRadius.circular(4)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 13, color: Colors.white), const SizedBox(width: 3)],
        Text(text, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.2)),
      ],
    ),
  );
}

class Thumbnail extends StatelessWidget {
  const Thumbnail(this.item, {super.key, this.radius = UT.rMd, this.hd = false, this.cacheWidth});
  final YtItem item;
  final double radius;
  final bool hd;
  final double? cacheWidth;
  @override
  Widget build(BuildContext context) {
    final badge = item.kind == YtKind.playlist
        ? _Badge(item.videos > 0 ? '${item.videos}' : 'Playlist', icon: Icons.playlist_play)
        : item.live
        ? const _Badge('AO VIVO', color: UT.red)
        : item.duration > 0
        ? _Badge(durationLabel(item.duration))
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            NetImage(hd ? item.bestCover : item.cover, cacheWidth: cacheWidth),
            if (badge != null) Positioned(right: 6, bottom: 6, child: badge),
          ],
        ),
      ),
    );
  }
}

/// Full-width feed card: thumbnail, channel avatar, title and meta.
class VideoCard extends StatelessWidget {
  const VideoCard(this.item, {super.key, this.onTap, this.rounded = false});
  final YtItem item;
  final VoidCallback? onTap;

  /// Grid cells use rounded thumbnails; the phone list is edge-to-edge.
  final bool rounded;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return InkWell(
      onTap: onTap ?? () => openItem(context, item),
      child: Padding(
        padding: const EdgeInsets.only(bottom: UT.s6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Thumbnail(item, radius: rounded ? UT.rMd : 0, hd: true, cacheWidth: rounded ? width / 2 : width),
            Padding(
              padding: const EdgeInsets.fromLTRB(UT.s3, UT.s3, 0, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: () => openChannel(context, item.channelUrl, title: item.channel),
                    child: Avatar(item.channelAvatar),
                  ),
                  const SizedBox(width: UT.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.28, color: UT.text),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          metaLine(item),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: UT.text2, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                  if (item.videoId != null) TrackActionsButton(track: item.toTrack(), item: item),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact row used in "up next", search, playlists and channel lists.
class VideoRow extends StatelessWidget {
  const VideoRow(this.item, {super.key, this.onTap, this.showChannel = true});
  final YtItem item;
  final VoidCallback? onTap;
  final bool showChannel;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap ?? () => openItem(context, item),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(UT.s3, 6, 0, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 160, child: Thumbnail(item, radius: UT.rSm, cacheWidth: 160)),
            const SizedBox(width: UT.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.28, color: UT.text),
                  ),
                  const SizedBox(height: 4),
                  if (showChannel && item.channel.isNotEmpty && item.kind != YtKind.playlist)
                    Text(item.channel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: UT.text2)),
                  Text(
                    metaLine(item, withChannel: item.kind == YtKind.playlist),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: UT.text2),
                  ),
                ],
              ),
            ),
            if (item.videoId != null) TrackActionsButton(track: item.toTrack(), item: item),
          ],
        ),
      ),
    );
  }
}

class ChannelTile extends StatelessWidget {
  const ChannelTile(this.item, {super.key});
  final YtItem item;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => openItem(context, item),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: UT.s4, vertical: UT.s3),
      child: Row(
        children: [
          Avatar(item.cover, size: 72),
          const SizedBox(width: UT.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  [subscribersLabel(item.subscribers), if (item.videos > 0) '${compactCount(item.videos)} vídeos']
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  style: const TextStyle(fontSize: 12, color: UT.text2),
                ),
                const SizedBox(height: UT.s2),
                SubscribeButton(url: item.url, title: item.title, avatar: item.cover, dense: true),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// YouTube-style subscribe pill backed by local subscriptions.
class SubscribeButton extends ConsumerWidget {
  const SubscribeButton({super.key, required this.url, required this.title, this.avatar = '', this.dense = false});
  final String url;
  final String title;
  final String avatar;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(subscriptionsProvider);
    final notifier = ref.read(subscriptionsProvider.notifier);
    final subscribed = url.isNotEmpty && notifier.isSubscribed(url);
    void toggle() {
      HapticFeedback.mediumImpact();
      notifier.toggle(Subscription(url: url, title: title, avatar: avatar));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(subscribed ? 'Inscrição cancelada' : 'Inscrito em $title')),
      );
    }

    final size = dense ? const Size(0, 34) : const Size(0, 38);
    return AnimatedSwitcher(
      duration: UT.motion,
      child: subscribed
          ? FilledButton.icon(
              key: const ValueKey('on'),
              style: FilledButton.styleFrom(backgroundColor: UT.surface3, foregroundColor: UT.text, minimumSize: size),
              onPressed: toggle,
              icon: const Icon(Icons.notifications_none_rounded, size: 18),
              label: const Text('Inscrito'),
            )
          : FilledButton(
              key: const ValueKey('off'),
              style: FilledButton.styleFrom(minimumSize: size),
              onPressed: url.isEmpty ? null : toggle,
              child: const Text('Inscrever-se'),
            ),
    );
  }
}

/// Horizontal shelf of vertical Shorts cards.
class ShortsShelf extends StatelessWidget {
  const ShortsShelf(this.items, {super.key});
  final List<YtItem> items;
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: UT.s6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(UT.s3, 0, UT.s3, UT.s3),
            child: Row(
              children: [
                Icon(Icons.slow_motion_video, color: UT.red),
                SizedBox(width: UT.s2),
                Text('Shorts', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              ],
            ),
          ),
          SizedBox(
            height: 290,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: UT.s3),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: UT.s2),
              itemBuilder: (context, i) {
                final item = items[i];
                return GestureDetector(
                  onTap: () => openItem(context, item, shortsFeed: items),
                  child: SizedBox(
                    width: 164,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(UT.rMd),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          NetImage(item.cover, cacheWidth: 164),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.center,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Color(0xE6000000)],
                              ),
                            ),
                          ),
                          Positioned(
                            left: UT.s2,
                            right: UT.s2,
                            bottom: UT.s2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5, height: 1.25),
                                ),
                                if (item.views >= 0)
                                  Text(viewsLabel(item.views), style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Shimmering skeleton list shown while a feed loads.
class FeedSkeleton extends StatefulWidget {
  const FeedSkeleton({super.key, this.count = 3});
  final int count;
  @override
  State<FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<FeedSkeleton> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    Widget block({double? w, required double h, double r = 6}) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: UT.surface2, borderRadius: BorderRadius.circular(r)),
    );
    final content = Column(
      children: [
        for (var i = 0; i < widget.count; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: UT.s6),
            child: Column(
              children: [
                AspectRatio(aspectRatio: 16 / 9, child: block(h: double.infinity, r: 0)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(UT.s3, UT.s3, UT.s3, 0),
                  child: Row(
                    children: [
                      Container(width: 36, height: 36, decoration: const BoxDecoration(color: UT.surface2, shape: BoxShape.circle)),
                      const SizedBox(width: UT.s3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [block(h: 14), const SizedBox(height: 6), block(w: 180, h: 12)],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (reduce) return content;
    return FadeTransition(opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse), child: content);
  }
}

class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(UT.s8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.wifi_off_rounded, size: 44, color: UT.text3),
        const SizedBox(height: UT.s3),
        Text(message, textAlign: TextAlign.center, style: const TextStyle(color: UT.text2)),
        const SizedBox(height: UT.s4),
        OutlinedButton(onPressed: onRetry, child: const Text('Tentar de novo')),
      ],
    ),
  );
}
