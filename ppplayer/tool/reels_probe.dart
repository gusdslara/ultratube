// Manual check against the real service: dart run tool/reels_probe.dart
import 'package:ppplayer/core/api/innertube.dart';
import 'package:ppplayer/core/api/reels.dart';

Future<void> main() async {
  final tube = InnerTube();
  final reels = Reels((endpoint, body) => tube.post(endpoint, body));
  final sw = Stopwatch()..start();
  final first = await reels.feed(null);
  print('page 1: ${(first['items'] as List).length} items in ${sw.elapsedMilliseconds} ms, next=${first['next'] != null}');
  for (final i in first['items'] as List) {
    print('  ${i['url']} "${i['title']}" by "${i['channel']}" ${i['channelUrl']}');
  }
  sw.reset();
  final second = await reels.feed(first['next'] as String?);
  print('page 2: ${(second['items'] as List).length} items in ${sw.elapsedMilliseconds} ms, next=${second['next'] != null}');
  final id = ((second['items'] as List).last['url'] as String).split('/').last;
  sw.reset();
  print('info $id: ${await reels.info(id)} in ${sw.elapsedMilliseconds} ms');
}
