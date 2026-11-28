import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'twitch_api.dart';
import 'twitch_store.dart';

/// Most watched lives for a language ('' = all).
final twitchTopProvider = FutureProvider.family<List<TwitchStream>, String>((ref, language) async {
  final page = await TwitchApi.instance.topStreams(language: language, first: 30);
  return page.items;
});

final twitchGamesProvider = FutureProvider<List<TwitchGame>>((ref) async {
  final page = await TwitchApi.instance.topGames(first: 80);
  return page.items;
});

/// One category: header + its lives in the chosen language and order.
final twitchCategoryProvider = FutureProvider.family<(TwitchGame?, List<TwitchStream>), (String, String, TwitchSort)>((ref, args) async {
  final (game, page) = await TwitchApi.instance.gameStreams(args.$1, language: args.$2, first: 80, sort: args.$3);
  return (game, page.items);
});

/// Most viewed past broadcasts of one category.
final twitchCategoryVideosProvider = FutureProvider.family<List<TwitchVideo>, String>(
  (ref, name) => TwitchApi.instance.gameVideos(name),
);

final twitchChannelProvider = FutureProvider.family<TwitchChannel, String>((ref, login) => TwitchApi.instance.channel(login));

/// Live status of every followed channel, live ones first.
final twitchFollowedProvider = FutureProvider<List<TwitchChannel>>((ref) async {
  final follows = ref.watch(twitchFollowsProvider);
  if (follows.isEmpty) return const [];
  final found = await TwitchApi.instance.channels([for (final f in follows) f.login]);
  ref.read(twitchFollowsProvider.notifier).refresh(found.values);
  final list = [
    for (final f in follows)
      found[f.login] ?? TwitchChannel(id: '', login: f.login, displayName: f.displayName, avatar: f.avatar),
  ];
  list.sort((a, b) {
    if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
    if (a.isLive) return b.stream!.viewers.compareTo(a.stream!.viewers);
    return (b.lastStartedAt ?? DateTime(2000)).compareTo(a.lastStartedAt ?? DateTime(2000));
  });
  return list;
});

/// Channels, categories, live channels and videos for a query.
final twitchSearchProvider = FutureProvider.autoDispose.family<TwitchSearchResults, String>(
  (ref, query) => TwitchApi.instance.searchAll(query),
);

/// Autocomplete while typing.
final twitchSuggestionsProvider = FutureProvider.autoDispose.family<List<TwitchSuggestion>, String>(
  (ref, fragment) => TwitchApi.instance.suggestions(fragment),
);
