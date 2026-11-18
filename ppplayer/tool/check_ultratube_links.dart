import '../lib/features/shorts/short_link.dart';

void main() {
  const cases = <String, String?>{
    'https://www.youtube.com/shorts/abcdefghijk?si=share': 'abcdefghijk',
    'https://youtube.com/shorts/abc_def-123/': 'abc_def-123',
    'https://youtu.be/abcdefghijk?t=3': 'abcdefghijk',
    'https://youtube.com.evil.example/shorts/abcdefghijk': null,
    'https://evil.example/youtube.com/shorts/abcdefghijk': null,
    'http://youtube.com/shorts/abcdefghijk': null,
    'https://user@youtube.com/shorts/abcdefghijk': null,
    'https://youtube.com/watch?v=abcdefghijk': null,
    'https://youtube.com/shorts/short': null,
    'javascript:alert(1)': null,
  };
  for (final entry in cases.entries) {
    if (shortVideoId(entry.key) != entry.value)
      throw StateError('Failed: ${entry.key}');
  }
  print('PASS: ${cases.length} Shorts URL cases');
}
