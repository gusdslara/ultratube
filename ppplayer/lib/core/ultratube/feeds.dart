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

  /// Hive key of the last loaded page, shown at once on the next start.
  String? get cacheKey => null;

  /// A cached page this recent is shown as is; an older one is shown while
  /// a fresh page loads behind it.
  static const _freshFor = Duration(minutes: 10);
  static const _keepFor = Duration(days: 2);

  @override
  FeedState build() {
    final cached = _readCache();
    if (cached != null) {
      final (age, items) = cached;
      resetCursors();
      _seen.addAll([for (final i in items) i.videoId ?? i.url]);
      // A page that cannot continue from the cache (no cursor) reloads too.
      final stale = age > _freshFor || !canLoadMore;
      if (stale) Future.microtask(refresh);
      return FeedState(
        videos: [for (final i in items) if (!i.shorts) i],
        shorts: [for (final i in items) if (i.shorts) i],
        loading: stale,
        hasMore: true,
      );
    }
    Future.microtask(refresh);
    return const FeedState(loading: true);
  }

  /// The first page, in as many batches as it has sources: each batch is
  /// shown as soon as it arrives instead of waiting for the slowest one.
  Stream<List<YtItem>> first();
  Future<List<YtItem>> next();
  bool get canLoadMore;

  /// Back to page one (also called before continuing from a cached page).
  void resetCursors() {}

  (Duration, List<YtItem>)? _readCache() {
    final key = cacheKey;
    if (key == null) return null;
    try {
      final raw = UltratubeStore.box.get('feedCache:$key');
      if (raw is! Map) return null;
      final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(raw['at'] as int));
      if (age.isNegative || age > _keepFor) return null;
      final items = [for (final e in raw['items'] as List) YtItem.fromJson(Map<String, dynamic>.from(e as Map))];
      return items.where((i) => !i.shorts).length < 4 ? null : (age, items);
    } catch (error) {
      debugPrint('Ultratube: feed cache unreadable ($error)');
      return null;
    }
  }

  void _writeCache() {
    final key = cacheKey;
    if (key == null || state.videos.isEmpty) return;
    try {
      UltratubeStore.box.put('feedCache:$key', {
        'at': DateTime.now().millisecondsSinceEpoch,
        'items': [
          for (final i in state.videos.take(40)) i.toJson(),
          for (final i in state.shorts.take(20)) i.toJson(),
        ],
      });
    } catch (error) {
      debugPrint('Ultratube: feed cache not saved ($error)');
    }
  }

  void _append(List<YtItem> items, {bool reset = false, bool loading = false}) {
    final videos = reset ? <YtItem>[] : [...state.videos];
    final shorts = reset ? <YtItem>[] : [...state.shorts];
    for (final item in items) {
      final key = item.videoId ?? item.url;
      if (!_seen.add(key)) continue;
      if (item.kind != YtKind.video) continue;
      (item.shorts ? shorts : videos).add(item);
    }
    state = state.copyWith(videos: videos, shorts: shorts, loading: loading, error: null, hasMore: canLoadMore);
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    state = state.copyWith(loading: true, error: null);
    var shown = false;
    try {
      await for (final batch in first()) {
        if (generation != _generation) return;
        if (batch.isEmpty) continue;
        // What is on screen (a cached page) stays until the first batch lands.
        if (!shown) _seen.clear();
        _append(batch, reset: !shown, loading: true);
        shown = true;
      }
      if (generation != _generation) return;
      if (!shown) throw StateError('Sem conexão com o YouTube agora');
      state = state.copyWith(loading: false, hasMore: canLoadMore);
      _writeCache();
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
  String get cacheKey => 'kiosk:$id';
  @override
  bool get canLoadMore => _next != null;
  @override
  Stream<List<YtItem>> first() async* {
    final page = await _catalog.kiosk(id);
    _next = page.next;
    yield page.items;
  }

  @override
  Future<List<YtItem>> next() async {
    final page = await _catalog.more(_next!);
    _next = page.next;
    return page.items;
  }
}

final kioskFeedProvider = NotifierProvider.family<KioskFeed, FeedState, String>(KioskFeed.new);

/// "Para você". Signed in: the account's own YouTube home, in YouTube's
/// order. Signed out: recent uploads from subscriptions, "up next" of
/// recently watched videos and the category charts, computed on-device.
class ForYouFeed extends _PagedFeed {
  final _random = Random();
  int _historyCursor = 0;
  String? _trendingNext;
  bool _trendingDone = false;
  int _kioskCursor = 0;
  String? _homeNext;
  bool _homeDone = false;

  @override
  String get cacheKey => 'forYou';

  @override
  FeedState build() {
    // Signing in or out changes what "Para você" is.
    ref.listen(youtubeAccountProvider, (prev, next) {
      if ((prev == null) != (next == null)) refresh();
    });
    return super.build();
  }

  bool get _signedIn => ref.read(youtubeAccountProvider) != null;

  Set<String> get _watched => {for (final h in ref.read(historyProvider)) h.videoId ?? ''};

  @override
  bool get canLoadMore =>
      (_signedIn && !_homeDone) || _historyCursor < ref.read(historyProvider).length || !_trendingDone;

  @override
  void resetCursors() {
    _historyCursor = 0;
    _kioskCursor = 0;
    _trendingNext = null;
    _trendingDone = false;
    _homeNext = null;
    _homeDone = false;
  }

  /// The signed-in account's own YouTube recommendations, videos and Shorts
  /// (empty when signed out).
  Future<List<YtItem>> _youtubeHome() async {
    if (!_signedIn) _homeDone = true;
    if (_homeDone) return const [];
    try {
      final page = await YoutubeAccountNotifier.api.home(_homeNext);
      _homeNext = page.next;
      _homeDone = page.next == null;
      return page.items.where((i) => i.videoId != null).toList();
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
  Stream<List<YtItem>> first() async* {
    resetCursors();
    if (_signedIn) {
      // One request, already ranked by YouTube for this account.
      final home = await _youtubeHome();
      if (home.isNotEmpty) {
        yield home;
        return;
      }
    }
    // Signed out (or the account feed failed): every source is shown as it
    // lands. Subscriptions and charts take one or two requests; "up next"
    // of watched videos needs a full extraction each, so it goes last
    // instead of holding the page back.
    final sources = StreamController<List<YtItem>>();
    var pending = 2;
    for (final source in [_subscriptions(), _trending()]) {
      unawaited(
        source.then((items) => sources.add(items), onError: (Object _) {}).whenComplete(() {
          if (--pending == 0) sources.close();
        }),
      );
    }
    var shown = false;
    await for (final items in sources.stream) {
      final mixed = _mix([items]);
      if (mixed.isEmpty) continue;
      shown = true;
      yield mixed;
    }
    final related = _mix([await _related(2)]);
    if (related.isNotEmpty) {
      shown = true;
      yield related;
    }
    if (!shown) yield _mix([await _searchSeeds()]);
  }

  @override
  Future<List<YtItem>> next() async {
    if (_signedIn && !_homeDone) {
      final home = await _youtubeHome();
      if (home.isNotEmpty) return home;
    }
    return _mix(await Future.wait([_related(3), _trending()]));
  }
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

/// Source of the vertical Shorts player. Prefers YouTube's own Shorts feed
/// (the signed-in account's, else the regional one), two light requests per
/// page; falls back to searching topics the viewer watches when the feed is
/// unavailable or runs out.
class ShortsFeed {
  ShortsFeed(this._ref);
  final Ref _ref;
  String? _token;
  bool _real = true;
  int _searchPage = 0;

  Future<List<YtItem>> next() async {
    if (_real) {
      try {
        final page = await YoutubeAccountNotifier.api.shorts(_token);
        _token = page.next;
        _real = page.next != null;
        final items = page.items.where((i) => i.videoId != null).toList();
        if (items.isNotEmpty) return items;
      } catch (error) {
        debugPrint('Ultratube: feed de Shorts indisponível, usando busca: $error');
      }
      _real = false;
    }
    return discoverShorts(_ref, page: _searchPage++);
  }
}

/// A fresh [ShortsFeed] per Shorts screen.
final shortsFeedProvider = Provider<ShortsFeed Function()>((ref) => () => ShortsFeed(ref));
