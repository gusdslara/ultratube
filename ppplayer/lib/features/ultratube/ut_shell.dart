import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/player/player_provider.dart';
import '../../core/services/settings_provider.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/models/track.dart' show StreamLiveStatus;
import '../../core/twitch/twitch_store.dart' show twitchRouteFor;
import 'queue_sheet.dart';
import 'yt_widgets.dart';

/// Geometry shared with the app-wide video surface, which renders the mini
/// player's thumbnail when a video is playing.
/// Landscape phones get a compact shell (icon-only tabs, slimmer mini player)
/// so content keeps most of the short screen height.
abstract final class UtShellMetrics {
  static const miniGap = 6.0;
  static bool compact(Size screen) => screen.height < 500;
  static double navHeight(Size screen) => compact(screen) ? 44 : 58;
  static double miniHeight(Size screen) => compact(screen) ? 50 : 60;
  static Size thumb(Size screen) => compact(screen) ? const Size(76, 43) : const Size(96, 54);

  static Rect miniThumbRect(Size screen, double safeBottom) {
    final mini = miniHeight(screen), t = thumb(screen);
    final miniTop = screen.height - (navHeight(screen) + safeBottom) - miniGap - mini;
    return Rect.fromLTWH(14, miniTop + (mini - t.height) / 2, t.width, t.height);
  }
}

class _Tab {
  const _Tab(this.path, this.icon, this.active, this.label);
  final String path;
  final IconData icon;
  final IconData active;
  final String label;
}

const _tabs = [
  _Tab('/home', Icons.home_outlined, Icons.home_rounded, 'Início'),
  _Tab('/shorts', Icons.slow_motion_video_outlined, Icons.slow_motion_video, 'Shorts'),
  _Tab('/twitch', Icons.live_tv_outlined, Icons.live_tv_rounded, 'Twitch'),
  _Tab('/subscriptions', Icons.subscriptions_outlined, Icons.subscriptions, 'Inscrições'),
  _Tab('/you', Icons.account_circle_outlined, Icons.account_circle, 'Você'),
];

/// Flat, black YouTube-style tab bar.
class UtBottomNav extends StatelessWidget {
  const UtBottomNav({super.key});
  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final screen = MediaQuery.sizeOf(context);
    final compact = UtShellMetrics.compact(screen);
    return Container(
      height: UtShellMetrics.navHeight(screen) + safeBottom,
      padding: EdgeInsets.only(bottom: safeBottom),
      decoration: const BoxDecoration(
        color: UT.bg,
        border: Border(top: BorderSide(color: UT.line, width: 0.6)),
      ),
      child: Row(
        children: [
          for (final tab in _tabs)
            Expanded(
              child: _NavItem(
                tab: tab,
                compact: compact,
                selected: location.startsWith(tab.path) ||
                    (tab.path == '/you' && (location.startsWith('/library') || location.startsWith('/downloads'))),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.tab, required this.selected, this.compact = false});
  final _Tab tab;
  final bool selected;
  final bool compact;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: tab.label,
    child: InkResponse(
      radius: 36,
      onTap: () {
        HapticFeedback.selectionClick();
        context.go(tab.path);
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedSwitcher(
            duration: UT.motion,
            transitionBuilder: (child, a) => ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(a), child: child),
            child: Icon(
              selected ? tab.active : tab.icon,
              key: ValueKey(selected),
              size: 25,
              color: selected ? UT.text : UT.text2,
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 3),
            Text(
              tab.label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? UT.text : UT.text2,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

/// YouTube-style mini player: thumbnail (or live video), title, channel,
/// play/pause and close, with a hairline red progress bar on top.
class UtMiniPlayer extends ConsumerWidget {
  const UtMiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerProvider);
    final track = state.currentTrack;
    if (track == null) return const SizedBox.shrink();
    final showVideo = ref.watch(settingsProvider.select((s) => s.showVideo));
    final notifier = ref.read(playerProvider.notifier);
    final twitchRoute = twitchRouteFor(track);
    final youtube = (track.youtubeVideoId != null && track.spotifyId.contains(':') && !track.spotifyId.startsWith('local')) ||
        twitchRoute != null;
    final live = track.liveStatus == StreamLiveStatus.live;
    // A live has no timeline: show a full bar instead of a stuck one.
    final progress = live
        ? 1.0
        : state.duration.inMilliseconds > 0
        ? (state.position.inMilliseconds / state.duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final cover = track.localArtworkPath ?? track.albumImage ?? '';

    void open() {
      if (twitchRoute != null) {
        context.push(twitchRoute);
      } else if (youtube && track.spotifyId.startsWith('youtube:')) {
        context.push('/watch?v=${track.youtubeVideoId}');
      } else {
        showQueueSheet(context);
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, UtShellMetrics.miniGap),
      child: Material(
        color: UT.surface2,
        borderRadius: BorderRadius.circular(UT.rMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: open,
          child: SizedBox(
            height: UtShellMetrics.miniHeight(MediaQuery.sizeOf(context)),
            child: Stack(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 6),
                    // The live video surface is positioned over this box when
                    // video is on; otherwise the artwork shows here.
                    SizedBox.fromSize(
                      size: UtShellMetrics.thumb(MediaQuery.sizeOf(context)),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: showVideo && youtube
                            ? const ColoredBox(color: Colors.black)
                            : NetImage(cover, icon: Icons.music_note),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: UT.text),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            state.loadError != null ? 'Falha ao reproduzir' : track.artistName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: state.loadError != null ? UT.red : UT.text2),
                          ),
                        ],
                      ),
                    ),
                    if (state.isLoadingVideo && !state.isPlaying)
                      const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else
                      IconButton(
                        tooltip: state.isPlaying ? 'Pausar' : 'Reproduzir',
                        icon: Icon(state.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30),
                        onPressed: notifier.togglePlay,
                      ),
                    IconButton(
                      tooltip: 'Próximo',
                      icon: const Icon(Icons.skip_next_rounded, size: 28),
                      onPressed: notifier.skipNext,
                    ),
                    const SizedBox(width: 2),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 2,
                    color: UT.red,
                    backgroundColor: Colors.transparent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
