class UltratubeLyricLine {
  const UltratubeLyricLine(this.time, this.text);
  final Duration time;
  final String text;
}

List<UltratubeLyricLine> parseUltratubeLrc(String text) {
  final stamp = RegExp(r'\[(\d+):(\d{2})(?:\.(\d{1,3}))?\]');
  final offset =
      int.tryParse(
        RegExp(r'\[offset:([+-]?\d+)\]').firstMatch(text)?.group(1) ?? '',
      ) ??
      0;
  final result = <UltratubeLyricLine>[];
  for (final line in text.split('\n')) {
    final matches = stamp.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final lyric = line.substring(matches.last.end).trim();
    if (lyric.isEmpty) continue;
    for (final match in matches) {
      final seconds = int.parse(match.group(2)!);
      if (seconds >= 60) continue;
      final ms =
          int.parse(match.group(1)!) * 60000 +
          seconds * 1000 +
          int.parse((match.group(3) ?? '0').padRight(3, '0')) -
          offset;
      result.add(
        UltratubeLyricLine(Duration(milliseconds: ms < 0 ? 0 : ms), lyric),
      );
    }
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}
