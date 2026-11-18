import 'package:flutter_test/flutter_test.dart';
import 'package:ppplayer/core/api/yt_models.dart';
import 'package:ppplayer/features/ultratube/yt_widgets.dart';

void main() {
  test('video ids come from watch, short and youtu.be links', () {
    expect(youtubeIdFromUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(youtubeIdFromUrl('https://youtube.com/shorts/abcdefghijk'), 'abcdefghijk');
    expect(youtubeIdFromUrl('https://youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(youtubeIdFromUrl('https://www.youtube.com/channel/UCxyz'), isNull);
  });

  test('catalog items round-trip and become queue tracks', () {
    final item = YtItem.fromJson({
      'type': 'video',
      'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'title': 'Never Gonna Give You Up',
      'channel': 'Rick Astley',
      'artist': 'Rick Astley',
      'channelUrl': 'https://www.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw',
      'duration': 213,
      'views': 1500000000,
      'shorts': false,
    });
    expect(YtItem.fromJson(item.toJson()).title, item.title);
    final track = item.toTrack();
    expect(track.spotifyId, 'youtube:dQw4w9WgXcQ');
    expect(track.youtubeVideoId, 'dQw4w9WgXcQ');
    expect(track.durationMs, 213000);
    expect(YtItem.fromTrack(track).channelUrl, item.channelUrl);
  });

  test('pt-BR compact counts and labels', () {
    expect(compactCount(999), '999');
    expect(compactCount(1200), '1,2 mil');
    expect(compactCount(350000), '350 mil');
    expect(compactCount(1500000000), '1,5 bi');
    expect(viewsLabel(2300000), '2,3 mi de visualizações');
    expect(subscribersLabel(1), '1 inscrito');
    expect(durationLabel(213), '3:33');
    expect(durationLabel(3723), '1:02:03');
  });
}
