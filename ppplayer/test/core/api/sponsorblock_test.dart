import 'package:flutter_test/flutter_test.dart';
import 'package:ppplayer/core/api/sponsorblock.dart';

void main() {
  const body = '''
[
  {"videoID": "otherVideo1", "segments": [{"segment": [0, 30], "category": "sponsor"}]},
  {"videoID": "dQw4w9WgXcQ", "segments": [
    {"segment": [120.5, 150.0], "category": "selfpromo", "actionType": "skip"},
    {"segment": [10.0, 40.25], "category": "sponsor", "actionType": "skip"},
    {"segment": [60.0, 60.4], "category": "sponsor", "actionType": "skip"},
    {"segment": [70.0, 90.0], "category": "sponsor", "actionType": "mute"}
  ]}
]''';

  test('keeps only skip segments for the requested video, sorted', () {
    final segments = SponsorBlock.parse(body, 'dQw4w9WgXcQ');
    expect(segments, hasLength(2));
    expect(segments.first.start, const Duration(seconds: 10));
    expect(segments.first.end, const Duration(milliseconds: 40250));
    expect(segments.first.label, 'Patrocínio');
    expect(segments.last.category, 'selfpromo');
  });

  test('unknown video yields no segments', () {
    expect(SponsorBlock.parse(body, 'aaaaaaaaaaa'), isEmpty);
  });
}
