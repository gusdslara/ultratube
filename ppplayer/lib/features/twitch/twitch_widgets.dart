import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/ultratube_theme.dart';
import '../../core/twitch/twitch_api.dart';
import '../../core/twitch/twitch_store.dart';
import '../ultratube/yt_widgets.dart' show Avatar, NetImage, compactCount, durationLabel;

// -------------------------------------------------------------- helpers

String viewersLabel(int n) => n < 0 ? '' : '${compactCount(n)} ${n == 1 ? 'espectador' : 'espectadores'}';

/// "2 h 15 min ao vivo".
String uptimeLabel(DateTime? startedAt) {
  if (startedAt == null) return '';
  final d = DateTime.now().toUtc().difference(startedAt.toUtc());
  if (d.isNegative) return '';
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')} min' : '$m min';
}

String agoLabel(DateTime? at) {
  if (at == null) return '';
  final d = DateTime.now().toUtc().difference(at.toUtc());
  if (d.inMinutes < 60) return 'há ${d.inMinutes.clamp(1, 59)} min';
  if (d.inHours < 24) return 'há ${d.inHours} h';
  if (d.inDays < 30) return 'há ${d.inDays} ${d.inDays == 1 ? 'dia' : 'dias'}';
  final mo = d.inDays ~/ 30;
  return mo < 12 ? 'há $mo ${mo == 1 ? 'mês' : 'meses'}' : 'há ${d.inDays ~/ 365} ano(s)';
}

void openTwitchLive(BuildContext context, String login) => context.push('/twitch/watch?c=${login.toLowerCase()}');
void openTwitchChannel(BuildContext context, String login) => context.push('/twitch/channel?c=${login.toLowerCase()}');
void openTwitchCategory(BuildContext context, String name) => context.push('/twitch/category?name=${Uri.encodeQueryComponent(name)}');
void openTwitchVod(BuildContext context, TwitchVideo v) => context.push('/twitch/watch?vod=${v.id}&c=${v.login.toLowerCase()}');

// --------------------------------------------------------------- badges

class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.color = const Color(0xCC000000)});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
    child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
  );
}

/// Preview picture with AO VIVO + viewers, or a VOD duration.
class TwitchThumb extends StatelessWidget {
  const TwitchThumb({super.key, required this.image, this.viewers = -1, this.live = true, this.duration = 0, this.radius = UT.rMd});
  final String image;
  final int viewers;
  final bool live;
  final int duration;
  final double radius;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          NetImage(image, icon: Icons.live_tv_outlined, cacheWidth: 480),
          if (live) const Positioned(left: 8, top: 8, child: _Pill('AO VIVO', color: UT.red)),
          if (live && viewers >= 0) Positioned(left: 8, bottom: 8, child: _Pill(viewersLabel(viewers))),
          if (!live && duration > 0) Positioned(right: 8, bottom: 8, child: _Pill(durationLabel(duration))),
        ],
      ),
    ),
  );
}

/// Full-width live card (feed style).
class TwitchStreamCard extends StatelessWidget {
  const TwitchStreamCard(this.stream, {super.key, this.padding = const EdgeInsets.fromLTRB(12, 0, 12, 18)});
  final TwitchStream stream;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${stream.displayName}, ao vivo: ${stream.title}',
    child: InkWell(
      onTap: () => openTwitchLive(context, stream.login),
      onLongPress: () => openTwitchChannel(context, stream.login),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TwitchThumb(image: stream.previewAt(640, 360), viewers: stream.viewers),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(onTap: () => openTwitchChannel(context, stream.login), child: _LiveAvatar(stream.avatar, size: 38)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(stream.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, height: 1.3)),
                      const SizedBox(height: 3),
                      Text(stream.displayName, style: const TextStyle(color: UT.text2, fontSize: 12.5)),
                      if (stream.game.isNotEmpty)
                        GestureDetector(
                          onTap: () => openTwitchCategory(context, stream.game),
                          child: Text(stream.game, style: const TextStyle(color: UT.text2, fontSize: 12.5)),
                        ),
                      if (stream.tags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 4, children: [for (final t in stream.tags.take(3)) TwitchTag(t)]),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Compact row (search results, category lists in landscape).
class TwitchStreamRow extends StatelessWidget {
  const TwitchStreamRow(this.stream, {super.key});
  final TwitchStream stream;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => openTwitchLive(context, stream.login),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 168, child: TwitchThumb(image: stream.previewAt(440, 248), viewers: stream.viewers, radius: UT.rSm)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stream.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                const SizedBox(height: 4),
                Text(stream.displayName, style: const TextStyle(color: UT.text2, fontSize: 12)),
                if (stream.game.isNotEmpty) Text(stream.game, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: UT.text2, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Small pill for stream and category tags.
class TwitchTag extends StatelessWidget {
  const TwitchTag(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: UT.surface2, borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: const TextStyle(fontSize: 11.5, color: UT.text2, fontWeight: FontWeight.w600)),
  );
}

class _LiveAvatar extends StatelessWidget {
  const _LiveAvatar(this.url, {this.size = 40, this.live = true});
  final String url;
  final double size;
  final bool live;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: live ? UT.red : Colors.transparent, width: 2)),
    child: Avatar(url, size: size - 4),
  );
}

/// Category box art with viewers.
class TwitchGameTile extends StatelessWidget {
  const TwitchGameTile(this.game, {super.key});
  final TwitchGame game;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: game.displayName,
    child: InkWell(
      borderRadius: BorderRadius.circular(UT.rSm),
      onTap: () => openTwitchCategory(context, game.name),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 285 / 380,
            child: ClipRRect(borderRadius: BorderRadius.circular(UT.rSm), child: NetImage(game.boxArt, icon: Icons.sports_esports_outlined, cacheWidth: 200)),
          ),
          const SizedBox(height: 6),
          Text(game.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          if (game.viewers >= 0) Text(viewersLabel(game.viewers), maxLines: 1, style: const TextStyle(color: UT.text2, fontSize: 11.5)),
        ],
      ),
    ),
  );
}

/// Channel row with live status (search, following).
class TwitchChannelTile extends StatelessWidget {
  const TwitchChannelTile(this.channel, {super.key});
  final TwitchChannel channel;
  @override
  Widget build(BuildContext context) {
    final s = channel.stream;
    return ListTile(
      onTap: () => s != null ? openTwitchLive(context, channel.login) : openTwitchChannel(context, channel.login),
      leading: _LiveAvatar(channel.avatar, size: 46, live: s != null),
      title: Text(channel.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        s != null
            ? [s.game, viewersLabel(s.viewers)].where((e) => e.isNotEmpty).join(' · ')
            : channel.followers >= 0
            ? '${compactCount(channel.followers)} seguidores'
            : 'Offline',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: s != null ? UT.text : UT.text2, fontSize: 12.5),
      ),
      trailing: FollowButton(login: channel.login, displayName: channel.displayName, avatar: channel.avatar, compact: true),
    );
  }
}

/// VOD (past broadcast) row.
class TwitchVodRow extends StatelessWidget {
  const TwitchVodRow(this.video, {super.key, this.showChannel = false});
  final TwitchVideo video;

  /// Lists that mix channels (search, category) name the broadcaster.
  final bool showChannel;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: video.processing ? null : () => openTwitchVod(context, video),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 168, child: TwitchThumb(image: video.thumbnail, live: false, duration: video.lengthSeconds, radius: UT.rSm)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                const SizedBox(height: 4),
                if (showChannel && (video.displayName.isNotEmpty || video.login.isNotEmpty))
                  Text(
                    video.displayName.isNotEmpty ? video.displayName : video.login,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: UT.text, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                Text(
                  [if (video.game.isNotEmpty) video.game, '${compactCount(video.views)} visualizações', agoLabel(video.publishedAt)].join(' · '),
                  maxLines: 2,
                  style: const TextStyle(color: UT.text2, fontSize: 12),
                ),
                if (video.processing) const Text('Processando…', style: TextStyle(color: UT.text3, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Local follow toggle (purple when not yet following, like Twitch).
class FollowButton extends ConsumerWidget {
  const FollowButton({super.key, required this.login, required this.displayName, this.avatar = '', this.compact = false});
  final String login;
  final String displayName;
  final String avatar;
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final following = ref.watch(twitchFollowsProvider.select((l) => l.any((f) => f.login == login.toLowerCase())));
    void toggle() {
      HapticFeedback.lightImpact();
      ref.read(twitchFollowsProvider.notifier).toggle(TwitchFollow(login: login, displayName: displayName, avatar: avatar));
    }

    if (compact) {
      return IconButton(
        tooltip: following ? 'Deixar de seguir' : 'Seguir',
        icon: Icon(following ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: following ? UT.twitch : UT.text2),
        onPressed: toggle,
      );
    }
    return AnimatedSwitcher(
      duration: UT.motion,
      child: following
          ? OutlinedButton.icon(
              key: const ValueKey('on'),
              onPressed: toggle,
              icon: const Icon(Icons.favorite_rounded, size: 18, color: UT.twitch),
              label: const Text('Seguindo'),
              style: OutlinedButton.styleFrom(foregroundColor: UT.text, side: const BorderSide(color: UT.line), shape: const StadiumBorder()),
            )
          : FilledButton.icon(
              key: const ValueKey('off'),
              onPressed: toggle,
              icon: const Icon(Icons.favorite_border_rounded, size: 18),
              label: const Text('Seguir'),
              style: FilledButton.styleFrom(backgroundColor: UT.twitch, foregroundColor: Colors.white, shape: const StadiumBorder()),
            ),
    );
  }
}

/// Selectable chip consistent with the Início chips.
class TwitchChip extends StatelessWidget {
  const TwitchChip({super.key, required this.label, required this.selected, required this.onTap, this.icon});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Material(
      color: selected ? UT.text : UT.surface2,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 16, color: selected ? UT.bg : UT.text), const SizedBox(width: 6)],
              Text(label, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: selected ? UT.bg : UT.text)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Grid of categories sized for the screen width.
SliverGrid twitchGameGrid(BuildContext context, List<TwitchGame> games) {
  final width = MediaQuery.sizeOf(context).width;
  final columns = (width / 130).floor().clamp(3, 8);
  return SliverGrid.builder(
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: 10,
      mainAxisSpacing: 14,
      childAspectRatio: 285 / (380 + 95),
    ),
    itemCount: games.length,
    itemBuilder: (context, i) => TwitchGameTile(games[i]),
  );
}

/// Live streams as full cards on phones, a grid on wide screens.
Widget twitchStreamSliver(BuildContext context, List<TwitchStream> streams) {
  final width = MediaQuery.sizeOf(context).width;
  if (width < 700) {
    return SliverList.builder(itemCount: streams.length, itemBuilder: (context, i) => TwitchStreamCard(streams[i]));
  }
  final columns = (width / 380).floor().clamp(2, 4);
  final cardWidth = (width - 24 - 12 * (columns - 1)) / columns;
  return SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    sliver: SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        childAspectRatio: cardWidth / (cardWidth * 9 / 16 + 130),
      ),
      itemCount: streams.length,
      itemBuilder: (context, i) => TwitchStreamCard(streams[i], padding: const EdgeInsets.only(bottom: 12)),
    ),
  );
}

/// Shimmer-free skeleton (static blocks) while a list loads.
class TwitchSkeleton extends StatelessWidget {
  const TwitchSkeleton({super.key, this.count = 3});
  final int count;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < count; i++)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(aspectRatio: 16 / 9, child: DecoratedBox(decoration: BoxDecoration(color: UT.surface2, borderRadius: BorderRadius.circular(UT.rMd)))),
              const SizedBox(height: 10),
              Row(
                children: [
                  const CircleAvatar(radius: 19, backgroundColor: UT.surface2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(height: 12, width: double.infinity, color: UT.surface2),
                        const SizedBox(height: 6),
                        Container(height: 10, width: 140, color: UT.surface2),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );
}
