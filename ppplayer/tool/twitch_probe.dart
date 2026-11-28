// Manual check against the real service: dart run tool/twitch_probe.dart
import 'package:ppplayer/core/twitch/twitch_api.dart';

Future<void> main() async {
  final api = TwitchApi.instance;
  final r = await api.searchAll('valorant');
  print('search: ${r.channels.length} channels (${r.channels.take(3).map((c) => '${c.login}${c.isLive ? '*' : ''}').join(', ')}), '
      '${r.games.length} games (${r.games.map((g) => g.name).join(', ')}), ${r.streams.length} streams, '
      '${r.videos.length} videos (${r.videos.take(2).map((v) => '${v.login}:${v.id}').join(', ')})');
  final s = await api.suggestions('gaul');
  print('suggestions: ${s.map((e) => '${e.text}[${e.login.isNotEmpty ? 'ch${e.live ? '*' : ''}' : e.game.isNotEmpty ? 'game' : 'txt'}]').join(', ')}');
  final s2 = await api.suggestions('fort');
  print('suggestions: ${s2.map((e) => '${e.text}[${e.login.isNotEmpty ? 'ch' : e.game.isNotEmpty ? 'game:${e.game}' : 'txt'}]').join(', ')}');
  for (final sort in TwitchSort.values) {
    final (g, p) = await api.gameStreams('Just Chatting', language: 'pt', first: 5, sort: sort);
    print('${sort.name}: ${g?.displayName} tags=${g?.tags} followers=${g?.followers} -> ${p.items.map((e) => '${e.login}:${e.viewers}').join(', ')}');
  }
  final v = await api.gameVideos('VALORANT', first: 3);
  print('videos: ${v.map((e) => '${e.login} "${e.title}" ${e.views}').join(' | ')}');
  final d = await api.deviceCode();
  print('device: ${d['user_code']} ${d['verification_uri']} interval=${d['interval']} expires=${d['expires_in']}');
  print('poll: ${await api.deviceToken(d['device_code'] as String)}');
  print('validate bad: ${await api.validate('invalidtoken')}');
  print('profile: ${await api.profile('gaules')}');
  try {
    await api.followed('invalidtoken', '1');
  } catch (e) {
    print('followed with bad token -> $e');
  }
}
