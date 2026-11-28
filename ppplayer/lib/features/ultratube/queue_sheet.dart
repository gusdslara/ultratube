import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/yt_models.dart';
import '../../core/models/track.dart' show QueueItemOrigin;
import '../../core/player/player_provider.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/ultratube/ultratube_store.dart';
import 'playlist_picker.dart';
import 'yt_widgets.dart';

Future<void> showQueueSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const _QueueSheet(),
);

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.72,
    minChildSize: 0.4,
    maxChildSize: 0.95,
    builder: (context, controller) => QueueView(controller: controller),
  );
}

/// YouTube-style queue: reorder, swipe to remove, shuffle, repeat,
/// autoplay, clear and save as playlist. Also embedded in the video menu.
class QueueView extends ConsumerWidget {
  const QueueView({super.key, this.controller});
  final ScrollController? controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final autoplay = ref.watch(ultratubeAutoplayProvider);
    final tracks = state.queue;
    final current = state.currentIndex;
    final upcoming = (tracks.length - current - 1).clamp(0, tracks.length);

    return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(UT.s5, 0, UT.s2, UT.s2),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Fila', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      Text(
                        upcoming == 0 ? 'Nada depois deste' : '$upcoming a seguir',
                        style: const TextStyle(color: UT.text2, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Embaralhar',
                  isSelected: state.isShuffled,
                  icon: const Icon(Icons.shuffle),
                  selectedIcon: const Icon(Icons.shuffle, color: UT.red),
                  onPressed: notifier.toggleShuffle,
                ),
                IconButton(
                  tooltip: 'Repetir',
                  isSelected: state.repeatMode != RepeatMode.none,
                  icon: Icon(state.repeatMode == RepeatMode.one ? Icons.repeat_one : Icons.repeat),
                  selectedIcon: Icon(state.repeatMode == RepeatMode.one ? Icons.repeat_one : Icons.repeat, color: UT.red),
                  onPressed: notifier.cycleRepeat,
                ),
                PopupMenuButton<String>(
                  tooltip: 'Mais',
                  onSelected: (v) async {
                    switch (v) {
                      case 'save':
                        final items = [
                          for (final t in tracks)
                            if (t.youtubeVideoId != null) YtItem.fromTrack(t),
                        ];
                        await saveToNewPlaylist(context, ref, items);
                      case 'clear':
                        notifier.clearUpcoming();
                        HapticFeedback.lightImpact();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'save', child: ListTile(leading: Icon(Icons.playlist_add), title: Text('Salvar como playlist'))),
                    PopupMenuItem(value: 'clear', child: ListTile(leading: Icon(Icons.clear_all), title: Text('Limpar a seguir'))),
                  ],
                ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: UT.s4),
            padding: const EdgeInsets.symmetric(horizontal: UT.s3),
            decoration: BoxDecoration(color: UT.surface2, borderRadius: BorderRadius.circular(UT.rMd)),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: autoplay,
              onChanged: ref.read(ultratubeAutoplayProvider.notifier).set,
              title: const Text('Reprodução automática', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: const Text('Continua com vídeos relacionados quando a fila acaba'),
            ),
          ),
          const SizedBox(height: UT.s2),
          Expanded(
            child: tracks.isEmpty
                ? const Center(child: Text('A fila está vazia', style: TextStyle(color: UT.text2)))
                : ReorderableListView.builder(
                    scrollController: controller,
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.only(bottom: UT.s8),
                    itemCount: tracks.length,
                    onReorder: (from, to) {
                      HapticFeedback.selectionClick();
                      notifier.reorderQueue(from, to);
                    },
                    proxyDecorator: (child, _, _) => Material(color: UT.surface3, borderRadius: BorderRadius.circular(UT.rMd), child: child),
                    itemBuilder: (context, i) {
                      final t = tracks[i];
                      final playing = i == current;
                      final played = i < current;
                      final auto = t.queueOrigin == QueueItemOrigin.autoplay;
                      return Dismissible(
                        key: ValueKey(t.queueItemId ?? '${t.spotifyId}_$i'),
                        direction: playing ? DismissDirection.none : DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: UT.s6),
                          color: UT.redSoft,
                          child: const Icon(Icons.delete_outline, color: UT.red),
                        ),
                        onDismissed: (_) => notifier.removeFromQueue(i),
                        child: InkWell(
                          onTap: () => notifier.skipTo(i),
                          child: Opacity(
                            opacity: played ? 0.45 : 1,
                            child: Container(
                              color: playing ? UT.surface2 : null,
                              padding: const EdgeInsets.fromLTRB(UT.s2, 6, 0, 6),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 22,
                                    child: playing
                                        ? const Icon(Icons.graphic_eq, color: UT.red, size: 18)
                                        : Text('${i + 1}', textAlign: TextAlign.center, style: const TextStyle(color: UT.text3, fontSize: 12)),
                                  ),
                                  const SizedBox(width: 6),
                                  SizedBox(
                                    width: 96,
                                    height: 54,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: NetImage(t.localArtworkPath ?? t.albumImage ?? '', icon: Icons.music_note),
                                    ),
                                  ),
                                  const SizedBox(width: UT.s3),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          t.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                            color: playing ? UT.red : UT.text,
                                            height: 1.25,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          [
                                            t.artistName,
                                            if ((t.durationMs ?? 0) > 0) durationLabel((t.durationMs ?? 0) ~/ 1000),
                                            if (auto) 'automático',
                                          ].where((s) => s.isNotEmpty).join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(color: UT.text2, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                  ReorderableDragStartListener(
                                    index: i,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: UT.s3, vertical: UT.s3),
                                      child: Icon(Icons.drag_handle, color: UT.text3),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
    );
  }
}
