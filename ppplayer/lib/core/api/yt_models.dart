import '../models/track.dart';

/// Video id from any YouTube URL (watch, youtu.be, shorts, live).
String? youtubeIdFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final id =
      uri.queryParameters['v'] ??
      (uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null);
  return id != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id) ? id : null;
}

enum YtKind { video, channel, playlist }

/// One entry of any catalog list (feed, search, channel tab, related).
class YtItem {
  const YtItem({
    required this.kind,
    required this.url,
    required this.title,
    this.channel = '',
    this.artist = '',
    this.channelUrl = '',
    this.channelAvatar = '',
    this.cover = '',
    this.coverHd = '',
    this.duration = 0,
    this.views = -1,
    this.uploaded = '',
    this.uploadedAt = 0,
    this.shorts = false,
    this.live = false,
    this.verified = false,
    this.subscribers = -1,
    this.videos = -1,
  });

  factory YtItem.fromJson(Map<String, dynamic> j) => YtItem(
    kind: switch (j['type']) {
      'channel' => YtKind.channel,
      'playlist' => YtKind.playlist,
      _ => YtKind.video,
    },
    url: j['url'] as String? ?? '',
    title: j['title'] as String? ?? '',
    channel: j['channel'] as String? ?? '',
    artist: j['artist'] as String? ?? '',
    channelUrl: j['channelUrl'] as String? ?? '',
    channelAvatar: j['channelAvatar'] as String? ?? '',
    cover: j['cover'] as String? ?? '',
    coverHd: j['coverHd'] as String? ?? '',
    duration: (j['duration'] as num?)?.toInt() ?? 0,
    views: (j['views'] as num?)?.toInt() ?? -1,
    uploaded: j['uploaded'] as String? ?? '',
    uploadedAt: (j['uploadedAt'] as num?)?.toInt() ?? 0,
    shorts: j['shorts'] as bool? ?? false,
    live: j['live'] as bool? ?? false,
    verified: j['verified'] as bool? ?? false,
    subscribers: (j['subscribers'] as num?)?.toInt() ?? -1,
    videos: (j['videos'] as num?)?.toInt() ?? -1,
  );

  Map<String, dynamic> toJson() => {
    'type': kind.name,
    'url': url,
    'title': title,
    'channel': channel,
    'artist': artist,
    'channelUrl': channelUrl,
    'channelAvatar': channelAvatar,
    'cover': cover,
    'coverHd': coverHd,
    'duration': duration,
    'views': views,
    'uploaded': uploaded,
    'uploadedAt': uploadedAt,
    'shorts': shorts,
    'live': live,
    'verified': verified,
    'subscribers': subscribers,
    'videos': videos,
  };

  final YtKind kind;
  final String url;
  final String title;
  final String channel;
  final String artist;
  final String channelUrl;
  final String channelAvatar;
  final String cover;

  /// Largest available artwork (player, notification, full-width cards).
  final String coverHd;
  final int duration;

  String get bestCover => coverHd.isNotEmpty ? coverHd : cover;
  final int views;
  final String uploaded;
  final int uploadedAt;
  final bool shorts;
  final bool live;
  final bool verified;
  final int subscribers;
  final int videos;

  String? get videoId => kind == YtKind.video ? youtubeIdFromUrl(url) : null;

  /// Queue entry for the shared player.
  Track toTrack() {
    final id = videoId ?? '';
    return Track(
      spotifyId: shorts ? 'short:$id' : 'youtube:$id',
      name: title,
      artistId: channelUrl,
      artistName: artist.isNotEmpty ? artist : channel,
      youtubeVideoId: id,
      albumImage: bestCover.isNotEmpty
          ? bestCover
          : 'https://i.ytimg.com/vi/$id/hq720.jpg',
      durationMs: live ? null : duration * 1000,
      liveStatus: live ? StreamLiveStatus.live : StreamLiveStatus.unknown,
    );
  }

  /// Rebuilds a catalog item from a queued track (watch page fallback).
  factory YtItem.fromTrack(Track t) => YtItem(
    kind: YtKind.video,
    url: 'https://www.youtube.com/watch?v=${t.youtubeVideoId}',
    title: t.name,
    channel: t.artistName,
    artist: t.artistName,
    channelUrl: t.artistId.startsWith('http') ? t.artistId : '',
    cover: t.albumImage ?? '',
    duration: (t.durationMs ?? 0) ~/ 1000,
    shorts: t.spotifyId.startsWith('short:'),
    live: t.liveStatus == StreamLiveStatus.live,
  );
}

class YtPage {
  const YtPage(this.items, this.next, {this.suggestion = '', this.corrected = false});
  factory YtPage.fromJson(Map<String, dynamic> j) => YtPage(
    [
      for (final e in (j['items'] as List? ?? const []))
        YtItem.fromJson(Map<String, dynamic>.from(e as Map)),
    ],
    j['next'] as String?,
    suggestion: j['suggestion'] as String? ?? '',
    corrected: j['corrected'] as bool? ?? false,
  );
  static const empty = YtPage([], null);
  final List<YtItem> items;
  final String? next;

  /// "Did you mean" text; [corrected] when results are already for it.
  final String suggestion;
  final bool corrected;
}

class YtPlaylist {
  const YtPlaylist({
    required this.url,
    required this.title,
    required this.channel,
    required this.channelUrl,
    required this.cover,
    required this.count,
    required this.page,
  });
  factory YtPlaylist.fromJson(String url, Map<String, dynamic> j) => YtPlaylist(
    url: url,
    title: j['title'] as String? ?? '',
    channel: j['channel'] as String? ?? '',
    channelUrl: j['channelUrl'] as String? ?? '',
    cover: j['cover'] as String? ?? '',
    count: (j['count'] as num?)?.toInt() ?? -1,
    page: YtPage.fromJson(j),
  );
  final String url;
  final String title;
  final String channel;
  final String channelUrl;
  final String cover;
  final int count;
  final YtPage page;
}

class YtChannel {
  const YtChannel({
    required this.url,
    required this.title,
    required this.avatar,
    required this.banner,
    required this.subscribers,
    required this.description,
    required this.verified,
    required this.tabs,
    required this.videos,
  });
  factory YtChannel.fromJson(Map<String, dynamic> j) => YtChannel(
    url: j['url'] as String? ?? '',
    title: j['title'] as String? ?? '',
    avatar: j['avatar'] as String? ?? '',
    banner: j['banner'] as String? ?? '',
    subscribers: (j['subscribers'] as num?)?.toInt() ?? -1,
    description: j['description'] as String? ?? '',
    verified: j['verified'] as bool? ?? false,
    tabs: [for (final t in (j['tabs'] as List? ?? const [])) t as String],
    videos: j['videos'] is Map
        ? YtPage.fromJson(Map<String, dynamic>.from(j['videos'] as Map))
        : YtPage.empty,
  );
  final String url;
  final String title;
  final String avatar;
  final String banner;
  final int subscribers;
  final String description;
  final bool verified;
  final List<String> tabs;
  final YtPage videos;
}

class YtVideo {
  const YtVideo({
    required this.item,
    required this.subscribers,
    required this.likes,
    required this.description,
    required this.related,
  });
  factory YtVideo.fromJson(Map<String, dynamic> j) => YtVideo(
    item: YtItem.fromJson({...j, 'type': 'video'}),
    subscribers: (j['subscribers'] as num?)?.toInt() ?? -1,
    likes: (j['likes'] as num?)?.toInt() ?? -1,
    description: j['description'] as String? ?? '',
    related: [
      for (final e in (j['related'] as List? ?? const []))
        YtItem.fromJson(Map<String, dynamic>.from(e as Map)),
    ],
  );
  final YtItem item;
  final int subscribers;
  final int likes;
  final String description;
  final List<YtItem> related;
}

class YtComment {
  const YtComment({
    required this.author,
    required this.avatar,
    required this.text,
    required this.likes,
    required this.uploaded,
    required this.pinned,
    required this.hearted,
    required this.replies,
  });
  factory YtComment.fromJson(Map<String, dynamic> j) => YtComment(
    author: j['author'] as String? ?? '',
    avatar: j['avatar'] as String? ?? '',
    text: j['text'] as String? ?? '',
    likes: (j['likes'] as num?)?.toInt() ?? -1,
    uploaded: j['uploaded'] as String? ?? '',
    pinned: j['pinned'] as bool? ?? false,
    hearted: j['hearted'] as bool? ?? false,
    replies: (j['replies'] as num?)?.toInt() ?? 0,
  );
  final String author;
  final String avatar;
  final String text;
  final int likes;
  final String uploaded;
  final bool pinned;
  final bool hearted;
  final int replies;
}
