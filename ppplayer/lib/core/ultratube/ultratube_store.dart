import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../api/yt_models.dart';

/// Device-local Ultratube state: subscriptions, watch history, recent
/// searches and playback preferences. No Google account is involved.
class UltratubeStore {
  static Box<dynamic>? _box;
  static Box<dynamic> get box => _box!;

  static Future<void> open() async {
    try {
      _box ??= await Hive.openBox<dynamic>('ultratube');
    } catch (error) {
      debugPrint('Ultratube: store unavailable ($error); using memory');
      _box ??= await Hive.openBox<dynamic>('ultratube', bytes: Uint8List(0));
    }
  }

  static List<Map<String, dynamic>> readList(String key) => [
    for (final e in (box.get(key, defaultValue: const <dynamic>[]) as List))
      Map<String, dynamic>.from(e as Map),
  ];
}

/// A followed channel.
class Subscription {
  const Subscription({
    required this.url,
    required this.title,
    this.avatar = '',
  });
  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
    url: j['url'] as String,
    title: j['title'] as String? ?? '',
    avatar: j['avatar'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'url': url,
    'title': title,
    'avatar': avatar,
  };
  final String url;
  final String title;
  final String avatar;

  /// Channel id (UC…) when the URL carries it; used to match equivalents.
  String get key {
    final m = RegExp(r'/channel/([A-Za-z0-9_-]+)').firstMatch(url);
    return m?.group(1) ?? url;
  }
}

class SubscriptionsNotifier extends Notifier<List<Subscription>> {
  static const _key = 'subscriptions';

  @override
  List<Subscription> build() => [
    for (final e in UltratubeStore.readList(_key)) Subscription.fromJson(e),
  ];

  void _save(List<Subscription> next) {
    next.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    state = next;
    UltratubeStore.box.put(_key, [for (final s in next) s.toJson()]);
  }

  bool isSubscribed(String channelUrl) {
    final probe = Subscription(url: channelUrl, title: '').key;
    return state.any((s) => s.key == probe);
  }

  void toggle(Subscription channel) {
    final key = channel.key;
    if (state.any((s) => s.key == key)) {
      _save([...state.where((s) => s.key != key)]);
    } else {
      _save([...state, channel]);
    }
  }

  /// Updates avatar/name when a channel page reveals fresher data.
  void refresh(Subscription channel) {
    final key = channel.key;
    if (!state.any((s) => s.key == key)) return;
    _save([
      for (final s in state)
        if (s.key == key) channel else s,
    ]);
  }

  /// Imports Google Takeout `subscriptions.csv` or a NewPipe/LibreTube JSON
  /// export. Returns how many new channels were added.
  int importFile(File file) {
    final text = file.readAsStringSync();
    final found = <Subscription>[];
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final data = jsonDecode(trimmed);
      final list = data is Map ? (data['subscriptions'] as List? ?? const []) : data as List;
      for (final raw in list) {
        final m = Map<String, dynamic>.from(raw as Map);
        final url = (m['url'] ?? m['channel_url'] ?? '') as String;
        final id = (m['channelId'] ?? m['channel_id'] ?? '') as String;
        final name = (m['name'] ?? m['title'] ?? m['channel_name'] ?? '') as String;
        final full = url.isNotEmpty
            ? url
            : id.isNotEmpty
            ? 'https://www.youtube.com/channel/$id'
            : '';
        if (full.contains('youtube.com')) {
          found.add(Subscription(url: full.replaceFirst('http://', 'https://'), title: name));
        }
      }
    } else {
      // Takeout CSV: "Channel Id,Channel Url,Channel Title" (header localised).
      for (final line in const LineSplitter().convert(text).skip(1)) {
        final cols = line.split(',');
        if (cols.length < 3) continue;
        final id = cols[0].trim();
        if (!id.startsWith('UC')) continue;
        found.add(
          Subscription(
            url: 'https://www.youtube.com/channel/$id',
            title: cols.sublist(2).join(',').trim(),
          ),
        );
      }
    }
    final existing = {for (final s in state) s.key};
    final fresh = [
      for (final s in found)
        if (existing.add(s.key)) s,
    ];
    if (fresh.isNotEmpty) _save([...state, ...fresh]);
    return fresh.length;
  }

  /// Adds channels that aren't followed yet (e.g. from the YouTube account),
  /// keeping the local ones. Returns how many were new.
  int merge(List<Subscription> channels) {
    final existing = {for (final s in state) s.key};
    final fresh = [
      for (final s in channels)
        if (existing.add(s.key)) s,
    ];
    if (fresh.isNotEmpty) _save([...state, ...fresh]);
    return fresh.length;
  }

  /// NewPipe-compatible export, so the list can move to other clients.
  String exportJson() => const JsonEncoder.withIndent('  ').convert({
    'app_version': 'Ultratube',
    'subscriptions': [
      for (final s in state) {'service_id': 0, 'url': s.url, 'name': s.title},
    ],
  });
}

final subscriptionsProvider =
    NotifierProvider<SubscriptionsNotifier, List<Subscription>>(
      SubscriptionsNotifier.new,
    );

/// Recently watched videos, newest first (seeds "Para você").
class HistoryNotifier extends Notifier<List<YtItem>> {
  static const _key = 'history';
  static const _limit = 300;

  @override
  List<YtItem> build() => [
    for (final e in UltratubeStore.readList(_key)) YtItem.fromJson(e),
  ];

  void add(YtItem item) {
    if (item.videoId == null || paused) return;
    final next = [
      item,
      ...state.where((e) => e.videoId != item.videoId),
    ].take(_limit).toList();
    state = next;
    UltratubeStore.box.put(_key, [for (final e in next) e.toJson()]);
  }

  void remove(YtItem item) {
    state = [...state.where((e) => e.videoId != item.videoId)];
    UltratubeStore.box.put(_key, [for (final e in state) e.toJson()]);
  }

  void clear() {
    state = const [];
    UltratubeStore.box.put(_key, const <dynamic>[]);
  }

  bool get paused => UltratubeStore.box.get('historyPaused', defaultValue: false) as bool;
  set paused(bool value) {
    UltratubeStore.box.put('historyPaused', value);
    ref.notifyListeners();
  }
}

final historyProvider = NotifierProvider<HistoryNotifier, List<YtItem>>(
  HistoryNotifier.new,
);

class SearchHistoryNotifier extends Notifier<List<String>> {
  static const _key = 'searches';
  @override
  List<String> build() => [
    for (final s in (UltratubeStore.box.get(_key, defaultValue: const <dynamic>[]) as List))
      s as String,
  ];
  void add(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    state = [q, ...state.where((s) => s.toLowerCase() != q.toLowerCase())].take(20).toList();
    UltratubeStore.box.put(_key, state);
  }

  void remove(String query) {
    state = [...state.where((s) => s != query)];
    UltratubeStore.box.put(_key, state);
  }
}

final searchHistoryProvider =
    NotifierProvider<SearchHistoryNotifier, List<String>>(
      SearchHistoryNotifier.new,
    );

/// A playlist kept on this device.
class LocalPlaylist {
  const LocalPlaylist({required this.id, required this.title, this.items = const []});
  factory LocalPlaylist.fromJson(Map<String, dynamic> j) => LocalPlaylist(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    items: [
      for (final e in (j['items'] as List? ?? const []))
        YtItem.fromJson(Map<String, dynamic>.from(e as Map)),
    ],
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'items': [for (final i in items) i.toJson()],
  };
  final String id;
  final String title;
  final List<YtItem> items;
  String get cover => items.isEmpty ? '' : items.first.bestCover;
  LocalPlaylist copyWith({String? title, List<YtItem>? items}) =>
      LocalPlaylist(id: id, title: title ?? this.title, items: items ?? this.items);
}

class PlaylistsNotifier extends Notifier<List<LocalPlaylist>> {
  static const _key = 'playlists';
  @override
  List<LocalPlaylist> build() => [
    for (final e in UltratubeStore.readList(_key)) LocalPlaylist.fromJson(e),
  ];

  void _save(List<LocalPlaylist> next) {
    state = next;
    UltratubeStore.box.put(_key, [for (final p in next) p.toJson()]);
  }

  LocalPlaylist create(String title, {List<YtItem> items = const []}) {
    final playlist = LocalPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? 'Nova playlist' : title.trim(),
      items: items,
    );
    _save([playlist, ...state]);
    return playlist;
  }

  void _update(String id, LocalPlaylist Function(LocalPlaylist) change) =>
      _save([for (final p in state) p.id == id ? change(p) : p]);

  /// Adds [item]; returns false when it was already there.
  bool add(String id, YtItem item) {
    final playlist = state.firstWhere((p) => p.id == id);
    if (playlist.items.any((i) => i.url == item.url)) return false;
    _update(id, (p) => p.copyWith(items: [...p.items, item]));
    return true;
  }

  void remove(String id, YtItem item) =>
      _update(id, (p) => p.copyWith(items: [...p.items.where((i) => i.url != item.url)]));

  void reorder(String id, int from, int to) => _update(id, (p) {
    final items = [...p.items];
    final moved = items.removeAt(from);
    items.insert(to > from ? to - 1 : to, moved);
    return p.copyWith(items: items);
  });

  void rename(String id, String title) => _update(id, (p) => p.copyWith(title: title));
  void delete(String id) => _save([...state.where((p) => p.id != id)]);
}

final playlistsProvider = NotifierProvider<PlaylistsNotifier, List<LocalPlaylist>>(
  PlaylistsNotifier.new,
);

/// Liked videos (local "Curtir").
class LikedNotifier extends Notifier<List<YtItem>> {
  static const _key = 'liked';
  @override
  List<YtItem> build() => [for (final e in UltratubeStore.readList(_key)) YtItem.fromJson(e)];
  bool isLiked(String url) => state.any((i) => i.url == url);
  void toggle(YtItem item) {
    state = isLiked(item.url) ? [...state.where((i) => i.url != item.url)] : [item, ...state];
    UltratubeStore.box.put(_key, [for (final i in state) i.toJson()]);
  }
}

final likedProvider = NotifierProvider<LikedNotifier, List<YtItem>>(LikedNotifier.new);

/// YouTube playlists bookmarked from search/channels.
class SavedPlaylistsNotifier extends Notifier<List<YtItem>> {
  static const _key = 'savedPlaylists';
  @override
  List<YtItem> build() => [for (final e in UltratubeStore.readList(_key)) YtItem.fromJson(e)];
  bool isSaved(String url) => state.any((i) => i.url == url);
  void toggle(YtItem item) {
    state = isSaved(item.url) ? [...state.where((i) => i.url != item.url)] : [item, ...state];
    UltratubeStore.box.put(_key, [for (final i in state) i.toJson()]);
  }
}

final savedPlaylistsProvider = NotifierProvider<SavedPlaylistsNotifier, List<YtItem>>(
  SavedPlaylistsNotifier.new,
);

/// YouTube-style autoplay: keep playing "up next" when the queue ends.
class AutoplayNotifier extends Notifier<bool> {
  @override
  bool build() => UltratubeStore.box.get('autoplay', defaultValue: true) as bool;
  void set(bool value) {
    state = value;
    UltratubeStore.box.put('autoplay', value);
  }
}

final ultratubeAutoplayProvider = NotifierProvider<AutoplayNotifier, bool>(
  AutoplayNotifier.new,
);

/// Skip community-reported sponsor segments (SponsorBlock).
class SponsorSkipNotifier extends Notifier<bool> {
  @override
  bool build() => UltratubeStore.box.get('sponsorSkip', defaultValue: true) as bool;
  void set(bool value) {
    state = value;
    UltratubeStore.box.put('sponsorSkip', value);
  }
}

final sponsorSkipProvider = NotifierProvider<SponsorSkipNotifier, bool>(SponsorSkipNotifier.new);

/// Highest video resolution to stream (YouTube ladders: 360…2160).
class VideoQualityNotifier extends Notifier<int> {
  static const options = [360, 480, 720, 1080, 1440, 2160];
  @override
  int build() => UltratubeStore.box.get('maxHeight', defaultValue: 1080) as int;
  void set(int height) {
    state = height;
    UltratubeStore.box.put('maxHeight', height);
  }
}

final videoQualityProvider = NotifierProvider<VideoQualityNotifier, int>(
  VideoQualityNotifier.new,
);
