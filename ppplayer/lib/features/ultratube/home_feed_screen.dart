import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ultratube/feeds.dart';
import 'yt_widgets.dart';

/// Início: "Para você" plus YouTube's own categories, YouTube-style.
class HomeFeedScreen extends ConsumerStatefulWidget {
  const HomeFeedScreen({super.key});
  @override
  ConsumerState<HomeFeedScreen> createState() => _HomeFeedScreenState();
}

class _HomeFeedScreenState extends ConsumerState<HomeFeedScreen> {
  String? _kiosk; // null = Para você

  @override
  Widget build(BuildContext context) {
    final kiosks = ref.watch(kiosksProvider).value ?? const <String>[];
    final provider = _kiosk == null ? forYouFeedProvider : kioskFeedProvider(_kiosk!);
    final feed = ref.watch(provider);
    final colors = Theme.of(context).colorScheme;

    Future<void> refresh() => _kiosk == null
        ? ref.read(forYouFeedProvider.notifier).refresh()
        : ref.read(kioskFeedProvider(_kiosk!).notifier).refresh();
    void more() => _kiosk == null
        ? ref.read(forYouFeedProvider.notifier).loadMore()
        : ref.read(kioskFeedProvider(_kiosk!).notifier).loadMore();

    // Shorts shelf after the third video, like the YouTube home.
    final videos = feed.videos;
    final shelfAt = videos.length < 3 ? videos.length : 3;
    final count = videos.length + (feed.shorts.isNotEmpty ? 1 : 0);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 700;
    final columns = (width / 380).floor().clamp(2, 4);
    final cardWidth = (width - 24 - 12 * (columns - 1)) / columns;

    return SafeArea(
      bottom: false,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 1200) more();
          return false;
        },
        child: RefreshIndicator(
          onRefresh: refresh,
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                floating: true,
                snap: true,
                backgroundColor: colors.surface,
                surfaceTintColor: Colors.transparent,
                titleSpacing: 12,
                title: const _Logo(),
                actions: [
                  IconButton(
                    tooltip: 'Buscar',
                    icon: const Icon(Icons.search),
                    onPressed: () => context.push('/search'),
                  ),
                  IconButton(
                    tooltip: 'Histórico',
                    icon: const Icon(Icons.history),
                    onPressed: () => context.push('/history'),
                  ),
                ],
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(48),
                  child: SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      children: [
                        _Chip(label: 'Para você', selected: _kiosk == null, onTap: () => setState(() => _kiosk = null)),
                        for (final id in kiosks)
                          _Chip(label: kioskLabel(id), selected: _kiosk == id, onTap: () => setState(() => _kiosk = id)),
                      ],
                    ),
                  ),
                ),
              ),
              if (feed.loading && videos.isEmpty)
                const SliverToBoxAdapter(child: FeedSkeleton())
              else if (feed.error != null && videos.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: ErrorRetry(
                      message: 'Não foi possível carregar o feed.\nVerifique sua conexão.',
                      onRetry: refresh,
                    ),
                  ),
                )
              else
              if (wide) ...[
                // Landscape / tablet: shorts shelf on top, then a card grid.
                SliverToBoxAdapter(child: ShortsShelf(feed.shorts)),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      childAspectRatio: cardWidth / (cardWidth * 9 / 16 + 112),
                    ),
                    itemCount: videos.length,
                    itemBuilder: (context, i) => VideoCard(videos[i], rounded: true),
                  ),
                ),
              ] else
                SliverList.builder(
                  itemCount: count,
                  itemBuilder: (context, i) {
                    if (feed.shorts.isNotEmpty) {
                      if (i == shelfAt) return ShortsShelf(feed.shorts);
                      if (i > shelfAt) return VideoCard(videos[i - 1]);
                    }
                    return VideoCard(videos[i]);
                  },
                ),
              SliverToBoxAdapter(
                child: feed.loading && videos.isNotEmpty
                    ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                    : const SizedBox(height: 140),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Image.asset('assets/logo.png', width: 28, height: 28, filterQuality: FilterQuality.medium),
      ),
      const SizedBox(width: 8),
      const Text('Ultratube', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
    ],
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? colors.onSurface : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
                color: selected ? colors.surface : colors.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
