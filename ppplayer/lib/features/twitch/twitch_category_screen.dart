import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/ultratube_theme.dart';
import '../../core/twitch/twitch_api.dart';
import '../../core/twitch/twitch_providers.dart';
import '../../core/twitch/twitch_store.dart';
import '../ultratube/yt_widgets.dart' show ErrorRetry, NetImage, compactCount;
import 'twitch_widgets.dart';

/// One category (game): its live channels, sortable, and its most viewed
/// past broadcasts.
class TwitchCategoryScreen extends ConsumerStatefulWidget {
  const TwitchCategoryScreen({super.key, required this.name});
  final String name;
  @override
  ConsumerState<TwitchCategoryScreen> createState() => _TwitchCategoryScreenState();
}

class _TwitchCategoryScreenState extends ConsumerState<TwitchCategoryScreen> {
  TwitchSort _sort = TwitchSort.viewers;
  bool _videos = false;

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    final language = ref.watch(twitchLanguageProvider);
    final key = (name, language, _sort);
    final data = ref.watch(twitchCategoryProvider(key));
    // Keep the header while another order or language loads.
    final game = data.value?.$1;

    Future<void> refresh() async {
      if (_videos) {
        ref.invalidate(twitchCategoryVideosProvider(name));
        await ref.read(twitchCategoryVideosProvider(name).future).then((_) {}, onError: (Object _) {});
      } else {
        ref.invalidate(twitchCategoryProvider(key));
        await ref.read(twitchCategoryProvider(key).future).then((_) {}, onError: (Object _) {});
      }
    }

    return Scaffold(
      backgroundColor: UT.bg,
      body: RefreshIndicator(
        color: UT.twitch,
        onRefresh: refresh,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: UT.bg,
              surfaceTintColor: Colors.transparent,
              title: Text(game?.displayName ?? name),
              actions: [
                if (!_videos)
                  PopupMenuButton<TwitchSort>(
                    tooltip: 'Ordenar',
                    icon: const Icon(Icons.sort_rounded),
                    initialValue: _sort,
                    onSelected: (s) => setState(() => _sort = s),
                    itemBuilder: (_) => [
                      for (final s in TwitchSort.values) CheckedPopupMenuItem(value: s, checked: s == _sort, child: Text(s.label)),
                    ],
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Idioma',
                  icon: const Icon(Icons.translate_rounded),
                  initialValue: language,
                  onSelected: ref.read(twitchLanguageProvider.notifier).set,
                  itemBuilder: (_) => [
                    for (final e in TwitchLanguageNotifier.options.entries)
                      CheckedPopupMenuItem(value: e.key, checked: e.key == language, child: Text(e.value)),
                  ],
                ),
              ],
            ),
            if (game != null) SliverToBoxAdapter(child: _GameHeader(game)),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    TwitchChip(label: 'Ao vivo', selected: !_videos, onTap: () => setState(() => _videos = false)),
                    TwitchChip(label: 'Vídeos', selected: _videos, onTap: () => setState(() => _videos = true)),
                  ],
                ),
              ),
            ),
            if (_videos)
              ...ref.watch(twitchCategoryVideosProvider(name)).when(
                loading: () => [const SliverToBoxAdapter(child: TwitchSkeleton())],
                error: (e, _) => [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: ErrorRetry(message: 'Não foi possível carregar os vídeos.', onRetry: () => ref.invalidate(twitchCategoryVideosProvider(name)))),
                  ),
                ],
                data: (videos) => videos.isEmpty
                    ? [const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('Nenhum vídeo nesta categoria.', style: TextStyle(color: UT.text2))))]
                    : [SliverList.builder(itemCount: videos.length, itemBuilder: (context, i) => TwitchVodRow(videos[i], showChannel: true))],
              )
            else
              ...data.when(
                loading: () => [const SliverToBoxAdapter(child: TwitchSkeleton())],
                error: (e, _) => [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: ErrorRetry(message: 'Não foi possível abrir a categoria.', onRetry: () => ref.invalidate(twitchCategoryProvider(key)))),
                  ),
                ],
                data: (d) => d.$2.isEmpty
                    ? [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(UT.s8),
                              child: Text(
                                language.isEmpty
                                    ? 'Ninguém ao vivo nesta categoria agora.'
                                    : 'Ninguém ao vivo em ${TwitchLanguageNotifier.options[language]} agora. Troque o idioma no topo para ver mais canais.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: UT.text2),
                              ),
                            ),
                          ),
                        ),
                      ]
                    : [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: Text(
                              '${d.$2.length} ${d.$2.length == 1 ? 'canal' : 'canais'} · ${TwitchLanguageNotifier.options[language] ?? 'Todos os idiomas'} · ${_sort.label}',
                              style: const TextStyle(color: UT.text2, fontSize: 12.5),
                            ),
                          ),
                        ),
                        twitchStreamSliver(context, d.$2),
                      ],
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        ),
      ),
    );
  }
}

class _GameHeader extends StatelessWidget {
  const _GameHeader(this.game);
  final TwitchGame game;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: AspectRatio(
            aspectRatio: 285 / 380,
            child: ClipRRect(borderRadius: BorderRadius.circular(UT.rSm), child: NetImage(game.boxArt, icon: Icons.sports_esports_outlined)),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(game.displayName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.2)),
              const SizedBox(height: 4),
              Text(
                [
                  if (game.viewers >= 0) viewersLabel(game.viewers),
                  if (game.followers >= 0) '${compactCount(game.followers)} seguidores',
                ].join(' · '),
                style: const TextStyle(color: UT.text2),
              ),
              if (game.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [for (final t in game.tags.take(5)) TwitchTag(t)]),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
