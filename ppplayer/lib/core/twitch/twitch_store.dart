import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/track.dart';
import '../ultratube/ultratube_store.dart';
import 'twitch_api.dart';

/// A followed Twitch channel (kept on the device; no Twitch account).
class TwitchFollow {
  const TwitchFollow({required this.login, required this.displayName, this.avatar = ''});
  factory TwitchFollow.fromJson(Map<String, dynamic> j) => TwitchFollow(
    login: j['login'] as String,
    displayName: j['displayName'] as String? ?? j['login'] as String,
    avatar: j['avatar'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {'login': login, 'displayName': displayName, 'avatar': avatar};
  final String login;
  final String displayName;
  final String avatar;
}

class TwitchFollowsNotifier extends Notifier<List<TwitchFollow>> {
  static const _key = 'twitchFollows';

  @override
  List<TwitchFollow> build() => [for (final e in UltratubeStore.readList(_key)) TwitchFollow.fromJson(e)];

  void _save(List<TwitchFollow> next) {
    next.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    state = next;
    UltratubeStore.box.put(_key, [for (final f in next) f.toJson()]);
  }

  bool isFollowing(String login) => state.any((f) => f.login == login.toLowerCase());

  void toggle(TwitchFollow channel) {
    final login = channel.login.toLowerCase();
    if (isFollowing(login)) {
      _save([...state.where((f) => f.login != login)]);
    } else {
      _save([...state, TwitchFollow(login: login, displayName: channel.displayName, avatar: channel.avatar)]);
    }
  }

  /// Keeps names/avatars fresh when a lookup returns newer data.
  void refresh(Iterable<TwitchChannel> channels) {
    final byLogin = {for (final c in channels) c.login.toLowerCase(): c};
    var changed = false;
    final next = <TwitchFollow>[];
    for (final f in state) {
      final c = byLogin[f.login];
      if (c != null && c.avatar.isNotEmpty && (c.avatar != f.avatar || c.displayName != f.displayName)) {
        changed = true;
        next.add(TwitchFollow(login: f.login, displayName: c.displayName, avatar: c.avatar));
      } else {
        next.add(f);
      }
    }
    if (changed) _save(next);
  }
}

final twitchFollowsProvider = NotifierProvider<TwitchFollowsNotifier, List<TwitchFollow>>(TwitchFollowsNotifier.new);

/// Directory language: '' = all, else an ISO code ("pt", "en"…).
class TwitchLanguageNotifier extends Notifier<String> {
  static const options = {'pt': 'Português', '': 'Todos os idiomas', 'en': 'Inglês', 'es': 'Espanhol'};
  @override
  String build() => UltratubeStore.box.get('twitchLang', defaultValue: 'pt') as String;
  void set(String value) {
    state = value;
    UltratubeStore.box.put('twitchLang', value);
  }
}

final twitchLanguageProvider = NotifierProvider<TwitchLanguageNotifier, String>(TwitchLanguageNotifier.new);

/// Preferred rendition: 'best', '1080p', '720p', '480p', '360p', '160p' or
/// 'audio_only'.
class TwitchQualityNotifier extends Notifier<String> {
  static const options = ['best', '1080p', '720p', '480p', '360p', '160p', 'audio_only'];
  static String label(String q) => switch (q) {
    'best' => 'Automática (melhor)',
    'audio_only' => 'Só áudio',
    _ => q,
  };
  @override
  String build() => UltratubeStore.box.get('twitchQuality', defaultValue: 'best') as String;
  void set(String value) {
    state = value;
    UltratubeStore.box.put('twitchQuality', value);
  }
}

final twitchQualityProvider = NotifierProvider<TwitchQualityNotifier, String>(TwitchQualityNotifier.new);

/// Queue entries for the shared player. The ids keep a `twitch:` prefix so
/// the shell knows which page to reopen.
Track twitchLiveTrack({required String login, required String displayName, required String url, String title = '', String preview = ''}) => Track(
  spotifyId: 'twitch:${login.toLowerCase()}',
  name: title.isEmpty ? displayName : title,
  artistId: 'twitch:${login.toLowerCase()}',
  artistName: displayName,
  albumName: 'Twitch',
  albumImage: preview,
  sourceType: TrackSourceType.networkStream,
  networkStreamUrl: url,
  isVideoFile: true,
  liveStatus: StreamLiveStatus.live,
);

Track twitchVodTrack({required TwitchVideo video, required String url}) => Track(
  spotifyId: 'twitchvod:${video.id}',
  name: video.title,
  artistId: 'twitch:${video.login}',
  artistName: video.displayName.isEmpty ? video.login : video.displayName,
  albumName: 'Twitch',
  albumImage: video.thumbnail,
  durationMs: video.lengthSeconds * 1000,
  sourceType: TrackSourceType.networkStream,
  networkStreamUrl: url,
  isVideoFile: true,
  liveStatus: StreamLiveStatus.onDemand,
);

/// Route that reopens the Twitch page of a queued track, if it is one.
String? twitchRouteFor(Track track) {
  final id = track.spotifyId;
  if (id.startsWith('twitch:')) return '/twitch/watch?c=${id.substring(7)}';
  if (id.startsWith('twitchvod:')) return '/twitch/watch?vod=${id.substring(10)}&c=${track.artistId.replaceFirst('twitch:', '')}';
  return null;
}
