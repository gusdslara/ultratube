/// Accept only actual YouTube hosts; never infer Shorts from video duration.
String? shortVideoId(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
    return null;
  }
  if (!{
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
  }.contains(uri.host.toLowerCase())) {
    return null;
  }
  final segments = uri.pathSegments.toList();
  if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
  String? id;
  if (uri.host == 'youtu.be' && segments.length == 1) {
    id = segments.first;
  } else if (segments.length == 2 && segments.first == 'shorts') {
    id = segments[1];
  }
  return id != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id) ? id : null;
}
