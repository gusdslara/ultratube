import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/ultratube_catalog.dart';
import 'ultratube_store.dart';
import 'youtube_account.dart';

const _catalog = UltratubeCatalog();

/// Human labels for NewPipe's YouTube kiosk ids.
String kioskLabel(String id) => switch (id.toLowerCase()) {
  'trending' => 'Em alta',
  'live' => 'Ao vivo',
  'trending_music' || 'music' => 'Música',
  'trending_gaming' || 'gaming' => 'Games',
  'trending_podcasts_episodes' || 'podcasts' => 'Podcasts',
  'news' => 'Notícias',
  'sports' => 'Esportes',
  'trending_movies_and_shows' || 'trending_movies_and_shows_trailers' => 'Trailers',
  _ => id.replaceAll('_', ' '),
};

final kiosksProvider = FutureProvider<List<String>>((ref) async {
  try {
    // YouTube retired the global Trending page in 2025; NewPipe's "Trending"
    // kiosk now always fails, so it is hidden. Category charts still work.
    final ids = (await _catalog.kiosks()).where((id) => id.toLowerCase() != 'trending').toList();
    const order = ['Trending', 'trending_music', 'live', 'trending_gaming', 'trending_podcasts_episodes'];
    int rank(String s) {
      final i = order.indexWhere((o) => o.toLowerCase() == s.toLowerCase());
      return i < 0 ? 99 : i;
    }

    ids.sort((a, b) => rank(a).compareTo(rank(b)));
    return ids;
  } catch (error) {
    debugPrint('Ultratube: kiosks indisponíveis: $error');
    return const [];
  }
});

/// One growing feed with "load more" support.
class FeedState {
  const FeedState({this.videos = const [], this.shorts = const [], this.loading = false, this.error, this.hasMore = false});
  final List<YtItem> videos;
  final List<YtItem> shorts;
  final bool loading;
  final String? error;
  final bool hasMore;
  FeedState copyWith({List<YtItem>? videos, List<YtItem>? shorts, bool? loading, Object? error = _keep, bool? hasMore}) => FeedState(
    videos: videos ?? this.videos,
    shorts: shorts ?? this.shorts,
    loading: loading ?? this.loading,
    error: identical(error, _keep) ? this.error : error as String?,
    hasMore: hasMore ?? this.hasMore,
  );
}

const _keep = Object();

abstract class _PagedFeed extends Notifier<FeedState> {
  final _seen = <String>{};
  int _generation = 0;

  @override
  FeedState build() {
    Future.microtask(refresh);
    return const FeedState(loading: true);
  }

  Future<List<YtItem>> first();
  Future<List<YtItem>> next();
  bool get canLoadMore;

  void _append(List<YtItem> items, {bool reset = false}) {
    final videos = reset ? <YtItem>[] : [...state.videos];
    final shorts = reset ? <YtItem>[] : [...state.shorts];
    for (final item in items) {
      final key = item.videoId ?? item.url;
      if (!_seen.add(key)) continue;
      if (item.kind != YtKind.video) continue;
      (item.shorts ? shorts : videos).add(item);
    }
    state = state.copyWith(videos: videos, shorts: shorts, loading: false, error: null, hasMore: canLoadMore);
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    _seen.clear();
    state = state.copyWith(loading: true, error: null);
    try {
      final items = await first();
      if (generation == _generation) _append(items, reset: true);
    } catch (error) {
      if (generation == _generation) state = state.copyWith(loading: false, error: '$error');
    }
  }

  Future<void> loadMore() async {
    if (state.loading || !canLoadMore) return;
    final generation = _generation;
    state = state.copyWith(loading: true);
    try {
      final items = await next();
      if (generation == _generation) _append(items);
    } catch (error) {
      if (generation == _generation) state = state.copyWith(loading: false, error: '$error');
    }
  }
}

/// A YouTube kiosk (Em alta, Música, Ao vivo…).
class KioskFeed extends _PagedFeed {
  KioskFeed(this.id);
  final String id;
  String? _next;
  @override
  bool get canLoadMore => _next != null;
  @override
  Future<List<YtItem>> first() async {
    final page = await _catalog.kiosk(id);
    _next = page.next;
    return page.items;
  }

  @override
  Future<List<YtItem>> next() async {
    final page = await _catalog.more(_next!);
    _next = page.next;
    return page.items;
  }
}

final kioskFeedProvider = NotifierProvider.family<KioskFeed, FeedState, String>(KioskFeed.new);

/// "Para você": recent uploads from subscriptions, "up next" of recently
/// watched videos and what's trending, interleaved and de-duplicated.
/// Everything is computed on-device from local history.
class ForYouFeed extends _PagedFeed {
  final _random = Random();
  int _historyCursor = 0;
  String? _trendingNext;
  bool _trendingDone = false;

  Set<String> get _watched => {for (final h in ref.read(historyProvider)) h.videoId ?? ''};

  String? _homeNext;
  bool _homeDone = true;

  @override
  bool get canLoadMore => _historyCursor < ref.read(historyProvider).length || !_trendingDone || !_homeDone;

  /// The signed-in account's own YouTube recommendations (empty when signed out).
  Future<List<YtItem>> _youtubeHome() async {
    if (ref.read(youtubeAccountProvider) == null) _homeDone = true;
    if (_homeDone) return const [];
    try {
      final page = await YoutubeAccountNotifier.api.home(_homeNext);
      _homeNext = page.next;
      _homeDone = page.next == null;
      return page.items.where((i) => !i.shorts && i.videoId != null).toList();
    } catch (error) {
      debugPrint('Ultratube: recomendações da conta indisponíveis: $error');
      _homeDone = true;
      return const [];
    }
  }

  Future<List<YtItem>> _related(int count) async {
    final history = ref.read(historyProvider);
    final seeds = history.skip(_historyCursor).take(count).toList();
    _historyCursor += seeds.length;
    final results = await Future.wait(
      seeds.map((seed) => _catalog.video(seed.url).then((v) => v.related.take(8).toList()).catchError((_) => <YtItem>[])),
    );
    return [for (final r in results) ...r];
  }

  int _kioskCursor = 0;

  /// Popular videos: walks the available category charts (music, live,
  /// gaming…), moving to the next one when a chart fails or runs out.
  Future<List<YtItem>> _trending() async {
    if (_trendingDone) return const [];
    final kiosks = await ref.read(kiosksProvider.future);
    while (true) {
      try {
        if (_trendingNext != null) {
          final page = await _catalog.more(_trendingNext!);
          _trendingNext = page.next;
          if (page.items.isNotEmpty) return page.items;
        }
        if (_kioskCursor >= kiosks.length) {
          _trendingDone = true;
          return const [];
        }
        final page = await _catalog.kiosk(kiosks[_kioskCursor++]);
        _trendingNext = page.next;
        if (page.items.isNotEmpty) return page.items;
      } catch (_) {
        _trendingNext = null; // broken chart: try the next one
      }
    }
  }

  /// Last-resort seeds when the viewer has no history, subscriptions or charts.
  Future<List<YtItem>> _searchSeeds() async {
    const seeds = ['músicas mais tocadas', 'vídeos em alta hoje', 'podcast brasil', 'humor brasil'];
    final results = await Future.wait(
      seeds.map((q) => _catalog.searchItems(q, kind: 'videos').then((p) => p.items).catchError((_) => <YtItem>[])),
    );
    return [for (final r in results) ...r];
  }

  Future<List<YtItem>> _subscriptions() async {
    final subs = [...ref.read(subscriptionsProvider)]..shuffle(_random);
    if (subs.isEmpty) return const [];
    try {
      final page = await _catalog.feed([for (final s in subs.take(40)) s.url]);
      final cutoff = DateTime.now().subtract(const Duration(days: 21)).millisecondsSinceEpoch;
      return page.items.where((i) => i.uploadedAt == 0 || i.uploadedAt > cutoff).take(30).toList();
    } catch (_) {
      return const [];
    }
  }

  List<YtItem> _mix(List<List<YtItem>> sources) {
    final watched = _watched;
    final lists = [
      for (final s in sources) [...s.where((i) => !watched.contains(i.videoId))]..shuffle(_random),
    ];
    final out = <YtItem>[];
    var i = 0;
    while (lists.any((l) => i < l.length)) {
      for (final l in lists) {
        if (i < l.length) out.add(l[i]);
      }
      i++;
    }
    return out;
  }

  @override
  Future<List<YtItem>> first() async {
    _historyCursor = 0;
    _kioskCursor = 0;
    _trendingNext = null;
    _trendingDone = false;
    _homeNext = null;
    _homeDone = false;
    final results = await Future.wait([_youtubeHome(), _subscriptions(), _related(4), _trending()]);
    var mixed = _mix(results);
    if (mixed.isEmpty) mixed = _mix([await _searchSeeds()]);
    if (mixed.isEmpty) throw StateError('Sem conexão com o YouTube agora');
    return mixed;
  }

  @override
  Future<List<YtItem>> next() async => _mix(await Future.wait([_youtubeHome(), _related(3), _trending()]));
}

final forYouFeedProvider = NotifierProvider<ForYouFeed, FeedState>(ForYouFeed.new);

/// Chronological uploads from every subscribed channel.
class SubscriptionFeed extends Notifier<FeedState> {
  int _generation = 0;
  @override
  FeedState build() {
    ref.listen(subscriptionsProvider, (prev, next) {
      if (prev?.length != next.length) refresh();
    });
    Future.microtask(refresh);
    return const FeedState(loading: true);
  }

  Future<void> refresh() async {
    final subs = ref.read(subscriptionsProvider);
    final generation = ++_generation;
    if (subs.isEmpty) {
      state = const FeedState();
      return;
    }
    state = state.copyWith(loading: true, error: null);
    try {
      final page = await _catalog.feed([for (final s in subs) s.url]);
      if (generation != _generation) return;
      state = FeedState(
        videos: [for (final i in page.items) if (!i.shorts) i],
        shorts: [for (final i in page.items) if (i.shorts) i],
      );
    } catch (error) {
      if (generation == _generation) state = state.copyWith(loading: false, error: '$error');
    }
  }
}

final subscriptionFeedProvider = NotifierProvider<SubscriptionFeed, FeedState>(SubscriptionFeed.new);

/// Shorts for the vertical player: seeded by the tapped Short when given,
/// otherwise searched from topics the viewer watches.
Future<List<YtItem>> discoverShorts(Ref ref, {int page = 0}) async {
  final history = ref.read(historyProvider);
  final topics = <String>{
    for (final h in history.take(12)) if (h.channel.isNotEmpty) h.channel,
  }.toList()
    ..shuffle();
  // Generic "#shorts"/"em alta" searches surface many region- or age-blocked
  // clips; popular topics play reliably.
  const popular = ['shorts brasil', 'shorts engraçados', 'shorts futebol', 'shorts música', 'mrbeast shorts', 'shorts curiosidades'];
  final queries = [...topics.take(2), popular[(page * 2) % popular.length], popular[(page * 2 + 1) % popular.length]];
  final results = await Future.wait(
    queries.map((q) => _catalog.searchItems(q, kind: 'shorts').then((p) => p.items).catchError((_) => <YtItem>[])),
  );
  final out = <YtItem>[];
  final seen = <String>{};
  final lists = [for (final r in results) [...r]..shuffle()];
  var i = 0;
  while (lists.any((l) => i < l.length)) {
    for (final l in lists) {
      if (i < l.length && l[i].shorts && seen.add(l[i].url)) out.add(l[i]);
    }
    i++;
  }
  return out;
}

final shortsDiscoveryProvider = Provider<Future<List<YtItem>> Function(int page)>(
  (ref) => (page) => discoverShorts(ref, page: page),
);
