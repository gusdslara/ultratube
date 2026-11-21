import 'innertube.dart';

/// POSTs one InnerTube call (`reel/...`) and returns the decoded reply.
typedef ReelPost = Future<Json> Function(String endpoint, Json body);

/// YouTube's own Shorts feed over InnerTube, the one youtube.com/shorts
/// plays. Pure Dart: the caller supplies [post], with the account's session
/// when there is one (personalised feed) or anonymous (regional feed).
///
/// Same JSON shapes as the Android `YoutubeAccount.shorts/shortInfo`.
class Reels {
  const Reels(this.post);
  final ReelPost post;

  static final _id = RegExp(r'^[a-zA-Z0-9_-]{11}$');

  /// `{items, next}`; [token] continues a previous page. Only the first item
  /// of a page carries title and channel; [info] completes the others.
  Future<Json> feed(String? token) async {
    final items = <String, Json>{};
    var sequence = token;
    if (sequence == null || sequence.isEmpty) {
      final first = await post('reel/reel_item_watch', {
        'disablePlayerResponse': true,
        'inputType': 'REEL_WATCH_INPUT_TYPE_SEEDLESS',
        'params': 'CA8%3D',
      });
      final id = str(first, ['replacementEndpoint', 'reelWatchEndpoint', 'videoId']);
      if (_id.hasMatch(id)) items[id] = _item(id, _overlay(first));
      sequence = str(first, ['sequenceContinuation']);
      if (sequence.isEmpty) return {'items': items.values.toList(), 'next': null};
    }
    final page = await post('reel/reel_watch_sequence', {'sequenceParams': sequence});
    for (final entry in (page['entries'] as List? ?? const [])) {
      final reel = obj(entry, ['command', 'reelWatchEndpoint']);
      final id = str(reel, ['videoId']);
      if (reel == null || !_id.hasMatch(id) || items.containsKey(id)) continue;
      final details = obj(reel, ['unserializedPrefetchData', 'playerResponse', 'videoDetails']);
      items[id] = _item(id, {
        if (details != null) ...{
          'title': str(details, ['title']),
          'channel': str(details, ['author']),
          'channelId': str(details, ['channelId']),
          'duration': int.tryParse(str(details, ['lengthSeconds'])) ?? 0,
        },
      });
    }
    final next = str(page, ['continuationEndpoint', 'continuationCommand', 'token']);
    return {'items': items.values.toList(), 'next': next.isEmpty ? null : next};
  }

  /// `{title, channel, channelUrl, channelAvatar, likes, comments}`.
  Future<Json> info(String videoId) async {
    if (!_id.hasMatch(videoId)) throw ArgumentError('ID de vídeo inválido');
    final page = await post('reel/reel_item_watch', {
      'disablePlayerResponse': true,
      'playerRequest': {'videoId': videoId},
    });
    final o = _overlay(page);
    return {
      'title': o['title'] ?? '',
      'channel': o['channel'] ?? '',
      'channelUrl': channelUrl(o['channelId'] as String? ?? ''),
      'channelAvatar': o['avatar'] ?? '',
      'likes': o['likes'] ?? '',
      'comments': o['comments'] ?? '',
    };
  }

  /// What the Shorts player overlay says about its video.
  static Json _overlay(Json page) {
    final out = <String, dynamic>{};
    final overlay = find(page['overlay'], 'reelPlayerOverlayViewModel');
    if (overlay == null) return out;
    final title = find(overlay, 'shortsVideoTitleViewModel');
    if (title != null) out['title'] = text(title['text']);
    final bar = find(overlay, 'reelChannelBarViewModel');
    if (bar != null) {
      final name = text(bar['channelName']);
      out['channel'] = name.startsWith('@') ? name.substring(1) : name;
      out['channelId'] = channelIdIn(bar);
      out['avatar'] = thumb(find(bar, 'avatarViewModel')?['image']);
    }
    final buttons = find(overlay, 'reelActionBarViewModel')?['buttonViewModels'];
    if (buttons is List) {
      for (var i = 0; i < buttons.length; i++) {
        final button = buttons[i];
        if (button is! Json) continue;
        if (button.containsKey('likeButtonViewModel')) {
          out['likes'] = str(find(find(button, 'defaultButtonViewModel'), 'buttonViewModel'), ['title']);
        } else if (i == 1) {
          // The comments button: its label is the count ("157").
          final label = str(button, ['buttonViewModel', 'title']);
          if (label.contains(RegExp(r'\d'))) out['comments'] = label;
        }
      }
    }
    return out;
  }

  static Json _item(String id, Json info) {
    final channel = info['channel'] as String? ?? '';
    // "oar2" is the vertical frame YouTube uses for Shorts covers.
    final cover = 'https://i.ytimg.com/vi/$id/oar2.jpg';
    return {
      'type': 'video',
      'url': 'https://www.youtube.com/shorts/$id',
      'title': info['title'] ?? '',
      'artist': channel,
      'channel': channel,
      'channelUrl': channelUrl(info['channelId'] as String? ?? ''),
      'channelAvatar': info['avatar'] ?? '',
      'cover': cover,
      'coverHd': cover,
      'duration': info['duration'] ?? 0,
      'views': -1,
      'uploaded': '',
      'uploadedAt': 0,
      'shorts': true,
      'verified': false,
      'live': false,
    };
  }
}
