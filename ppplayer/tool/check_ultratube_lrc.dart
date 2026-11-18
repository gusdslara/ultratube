import '../lib/features/player/ultratube_lrc.dart';
void main() {
  final lines = parseUltratubeLrc('[ar:Artist]\n[offset:100]\n[00:02.5][01:03.25]Repeated\n[00:01.001]First\n[00:99]Invalid\n[00:05.00]');
  if (lines.length != 3 || lines[0].time.inMilliseconds != 901 || lines[1].time.inMilliseconds != 2400 || lines[2].time.inMilliseconds != 63150 || lines[2].text != 'Repeated') throw StateError('LRC parsing regression');
  if (parseUltratubeLrc('Plain unsynced text').isNotEmpty) throw StateError('Plain text must not become timed lyrics');
  print('PASS: LRC fractions, offsets, repeated timestamps, metadata, invalid seconds and plain text');
}
