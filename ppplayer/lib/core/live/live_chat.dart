import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../ultratube/ultratube_store.dart';

// ------------------------------------------------------------------ model

/// One piece of a chat line: plain text or an inline emote image.
class ChatPart {
  const ChatPart.text(this.text) : emote = null;
  const ChatPart.emote(this.emote, {this.text = ''});
  final String text;

  /// Emote image URL; [text] keeps its code for accessibility.
  final String? emote;
}

/// A chat line from YouTube live chat or Twitch IRC, already parsed.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.author,
    required this.parts,
    this.color,
    this.avatar = '',
    this.badges = const [],
    this.highlight,
    this.highlightColor,
    this.isModerator = false,
    this.isOwner = false,
  });

  final String id;
  final String author;
  final List<ChatPart> parts;

  /// Name colour picked by the user (Twitch) or derived from the role.
  final Color? color;
  final String avatar;

  /// Small badge image URLs shown before the name.
  final List<String> badges;

  /// Super Chat / Bits / sub notice label (e.g. "R$ 10,00").
  final String? highlight;
  final Color? highlightColor;
  final bool isModerator;
  final bool isOwner;

  String get plain => parts.map((p) => p.text).join();
}

// ------------------------------------------------------------ preferences

/// How live chat and audience numbers appear over the video. Shared by
/// YouTube lives and Twitch.
@immutable
class LiveChatPrefs {
  const LiveChatPrefs({
    this.overlay = true,
    this.opacity = 0.55,
    this.showViewers = true,
    this.fontScale = 1.0,
  });

  /// Chat drawn on top of the video (transparent). Off = only in the panel.
  final bool overlay;

  /// Background opacity of the overlay lines, 0 (none) … 0.9.
  final double opacity;

  /// "1,2 mil assistindo" counter on the player.
  final bool showViewers;
  final double fontScale;

  LiveChatPrefs copyWith({bool? overlay, double? opacity, bool? showViewers, double? fontScale}) => LiveChatPrefs(
    overlay: overlay ?? this.overlay,
    opacity: opacity ?? this.opacity,
    showViewers: showViewers ?? this.showViewers,
    fontScale: fontScale ?? this.fontScale,
  );
}

class LiveChatPrefsNotifier extends Notifier<LiveChatPrefs> {
  static const _key = 'liveChatPrefs';

  @override
  LiveChatPrefs build() {
    final raw = UltratubeStore.box.get(_key);
    if (raw is! Map) return const LiveChatPrefs();
    final m = Map<String, dynamic>.from(raw);
    return LiveChatPrefs(
      overlay: m['overlay'] as bool? ?? true,
      opacity: (m['opacity'] as num?)?.toDouble() ?? 0.55,
      showViewers: m['showViewers'] as bool? ?? true,
      fontScale: (m['fontScale'] as num?)?.toDouble() ?? 1.0,
    );
  }

  void update(LiveChatPrefs next) {
    state = next;
    UltratubeStore.box.put(_key, {
      'overlay': next.overlay,
      'opacity': next.opacity,
      'showViewers': next.showViewers,
      'fontScale': next.fontScale,
    });
  }

  void toggleOverlay() => update(state.copyWith(overlay: !state.overlay));
  void toggleViewers() => update(state.copyWith(showViewers: !state.showViewers));
}

final liveChatPrefsProvider = NotifierProvider<LiveChatPrefsNotifier, LiveChatPrefs>(LiveChatPrefsNotifier.new);

// ---------------------------------------------------------- shared buffer

/// Rolling chat buffer any source can feed; widgets listen to it.
class ChatFeed extends ChangeNotifier {
  ChatFeed({this.limit = 250});
  final int limit;
  final List<ChatMessage> messages = [];
  String? error;
  bool connected = false;

  void addAll(Iterable<ChatMessage> items) {
    var added = false;
    for (final m in items) {
      messages.add(m);
      added = true;
    }
    if (!added) return;
    if (messages.length > limit) messages.removeRange(0, messages.length - limit);
    notifyListeners();
  }

  void setState({bool? connected, String? error, bool clearError = false}) {
    if (connected != null) this.connected = connected;
    if (clearError) this.error = null;
    if (error != null) this.error = error;
    notifyListeners();
  }
}

/// A live source of chat lines and audience numbers.
abstract class LiveSession {
  ChatFeed get chat;

  /// Concurrent viewers; -1 while unknown.
  ValueListenable<int> get viewers;
  void dispose();
}

// ------------------------------------------------------------ YouTube

/// Read-only YouTube live chat through the public web endpoints
/// (`/live_chat` page + `youtubei/v1/live_chat/get_live_chat`), plus the
/// "watching now" counter from `youtubei/v1/updated_metadata`. No account.
class YouTubeLiveSession implements LiveSession {
  YouTubeLiveSession(this.videoId, {http.Client? client}) : _http = client ?? http.Client() {
    unawaited(_start());
    _pollViewers();
    _viewerTimer = Timer.periodic(const Duration(seconds: 20), (_) => _pollViewers());
  }

  final String videoId;
  final http.Client _http;
  @override
  final ChatFeed chat = ChatFeed();
  final _viewers = ValueNotifier<int>(-1);
  @override
  ValueListenable<int> get viewers => _viewers;

  Timer? _poll;
  Timer? _viewerTimer;
  bool _disposed = false;
  String _clientVersion = '2.20261116.00.00';
  String? _continuation;
  final _seen = <String>{};

  static const _headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36',
    'Accept-Language': 'pt-BR,pt;q=0.9',
  };

  Map<String, dynamic> get _context => {
    'client': {'clientName': 'WEB', 'clientVersion': _clientVersion, 'hl': 'pt', 'gl': 'BR'},
  };

  Future<void> _start() async {
    try {
      final res = await _http
          .get(Uri.parse('https://www.youtube.com/live_chat?is_popout=1&v=$videoId'), headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (_disposed) return;
      final html = res.body;
      _clientVersion = RegExp(r'"INNERTUBE_CLIENT_VERSION":"([^"]+)"').firstMatch(html)?.group(1) ?? _clientVersion;
      final data = _initialData(html);
      final renderer = data?['contents']?['liveChatRenderer'] as Map?;
      if (renderer == null) {
        chat.setState(connected: false, error: 'O chat desta transmissão está desativado ou indisponível.');
        return;
      }
      // Prefer "Chat ao vivo" (every message) over the filtered top chat.
      _continuation = _allChatContinuation(renderer) ?? _firstContinuation(renderer['continuations']);
      chat.addAll(_parseActions(renderer['actions']));
      chat.setState(connected: true, clearError: true);
      _schedule(const Duration(milliseconds: 1500));
    } catch (error) {
      if (!_disposed) chat.setState(connected: false, error: 'Não foi possível conectar ao chat ($error).');
    }
  }

  void _schedule(Duration delay) {
    _poll?.cancel();
    if (_disposed || _continuation == null) return;
    _poll = Timer(delay, _fetch);
  }

  Future<void> _fetch() async {
    final token = _continuation;
    if (_disposed || token == null) return;
    try {
      final res = await _http
          .post(
            Uri.parse('https://www.youtube.com/youtubei/v1/live_chat/get_live_chat?prettyPrint=false'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'context': _context, 'continuation': token}),
          )
          .timeout(const Duration(seconds: 20));
      if (_disposed) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final live = json['continuationContents']?['liveChatContinuation'] as Map?;
      if (live == null) {
        chat.setState(connected: false, error: 'A transmissão terminou ou o chat foi encerrado.');
        return;
      }
      chat.addAll(_parseActions(live['actions']));
      final next = (live['continuations'] as List?)?.cast<Map>().firstOrNull;
      final body = next?.values.firstOrNull as Map?;
      _continuation = body?['continuation'] as String? ?? token;
      final timeout = (body?['timeoutMs'] as num?)?.toInt() ?? 3000;
      if (!chat.connected) chat.setState(connected: true, clearError: true);
      // Invalidation continuations suggest ~10 s (push based); poll faster so
      // the overlay feels live, but never hammer the endpoint.
      _schedule(Duration(milliseconds: timeout.clamp(1500, 4000)));
    } catch (_) {
      if (_disposed) return;
      chat.setState(connected: false);
      _schedule(const Duration(seconds: 6));
    }
  }

  Future<void> _pollViewers() async {
    try {
      final res = await _http
          .post(
            Uri.parse('https://www.youtube.com/youtubei/v1/updated_metadata?prettyPrint=false'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'context': _context, 'videoId': videoId}),
          )
          .timeout(const Duration(seconds: 15));
      if (_disposed) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      for (final action in (json['actions'] as List? ?? const [])) {
        final renderer = (action as Map)['updateViewershipAction']?['viewCount']?['videoViewCountRenderer'] as Map?;
        if (renderer == null) continue;
        final original = renderer['originalViewCount'];
        final count = int.tryParse('${original ?? ''}') ??
            int.tryParse(_text(renderer['viewCount']).replaceAll(RegExp(r'[^0-9]'), ''));
        if (count != null) _viewers.value = count;
      }
    } catch (_) {
      // Best effort; the counter just keeps its last value.
    }
  }

  static Map<String, dynamic>? _initialData(String html) {
    final m = RegExp(r'(?:window\["ytInitialData"\]|var ytInitialData)\s*=\s*(\{.+?\});\s*</script>', dotAll: true).firstMatch(html);
    if (m == null) return null;
    try {
      return jsonDecode(m.group(1)!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static String? _firstContinuation(Object? list) {
    for (final c in (list as List? ?? const [])) {
      for (final v in (c as Map).values) {
        final token = (v as Map?)?['continuation'];
        if (token is String) return token;
      }
    }
    return null;
  }

  static String? _allChatContinuation(Map renderer) {
    final items = renderer['header']?['liveChatHeaderRenderer']?['viewSelector']?['sortFilterSubMenuRenderer']?['subMenuItems'] as List?;
    if (items == null || items.length < 2) return null;
    return items[1]?['continuation']?['reloadContinuationData']?['continuation'] as String?;
  }

  List<ChatMessage> _parseActions(Object? actions) {
    final out = <ChatMessage>[];
    for (final a in (actions as List? ?? const [])) {
      final action = a as Map;
      final item = (action['addChatItemAction'] ?? action['replayChatItemAction']?['actions']?[0]?['addChatItemAction'])?['item'] as Map?;
      if (item == null) continue;
      final msg = _parseItem(item);
      if (msg != null && _seen.add(msg.id)) out.add(msg);
    }
    if (_seen.length > 2000) _seen.clear();
    return out;
  }

  static ChatMessage? _parseItem(Map item) {
    final text = item['liveChatTextMessageRenderer'] as Map?;
    final paid = item['liveChatPaidMessageRenderer'] as Map?;
    final member = item['liveChatMembershipItemRenderer'] as Map?;
    final sticker = item['liveChatPaidStickerRenderer'] as Map?;
    final r = text ?? paid ?? member ?? sticker;
    if (r == null) return null;
    final badges = <String>[];
    var mod = false, owner = false, verified = false, isMember = false;
    for (final b in (r['authorBadges'] as List? ?? const [])) {
      final badge = (b as Map)['liveChatAuthorBadgeRenderer'] as Map?;
      if (badge == null) continue;
      final icon = badge['icon']?['iconType'] as String?;
      if (icon == 'MODERATOR') mod = true;
      if (icon == 'OWNER') owner = true;
      if (icon == 'VERIFIED') verified = true;
      final thumb = (badge['customThumbnail']?['thumbnails'] as List?)?.cast<Map>().lastOrNull?['url'] as String?;
      if (thumb != null) {
        badges.add(thumb);
        isMember = true;
      }
    }
    final parts = <ChatPart>[];
    for (final run in (r['message']?['runs'] as List? ?? r['headerSubtext']?['runs'] as List? ?? const [])) {
      final m = run as Map;
      if (m['text'] is String) {
        parts.add(ChatPart.text(m['text'] as String));
      } else if (m['emoji'] is Map) {
        final emoji = m['emoji'] as Map;
        final thumbs = (emoji['image']?['thumbnails'] as List?)?.cast<Map>();
        final code = ((emoji['shortcuts'] as List?)?.firstOrNull as String?) ?? (emoji['emojiId'] as String? ?? '');
        final url = thumbs?.firstOrNull?['url'] as String?;
        // Standard unicode emoji come with an emojiId equal to the glyph.
        final isUnicode = emoji['isCustomEmoji'] != true && (emoji['emojiId'] as String? ?? '').runes.length <= 4;
        if (isUnicode) {
          parts.add(ChatPart.text(emoji['emojiId'] as String));
        } else if (url != null) {
          parts.add(ChatPart.emote(url.startsWith('//') ? 'https:$url' : url, text: code));
        }
      }
    }
    String? highlight;
    Color? highlightColor;
    if (paid != null || sticker != null) {
      highlight = _text((paid ?? sticker)!['purchaseAmountText']);
      final argb = ((paid ?? sticker)!['bodyBackgroundColor'] ?? (paid ?? sticker)!['backgroundColor']) as num?;
      highlightColor = argb == null ? const Color(0xFFFFCA28) : Color(argb.toInt());
    } else if (member != null) {
      highlight = 'Novo membro';
      highlightColor = const Color(0xFF0F9D58);
    }
    final avatar = (r['authorPhoto']?['thumbnails'] as List?)?.cast<Map>().firstOrNull?['url'] as String? ?? '';
    return ChatMessage(
      id: r['id'] as String? ?? '${DateTime.now().microsecondsSinceEpoch}',
      author: _text(r['authorName']),
      parts: parts,
      avatar: avatar,
      badges: badges,
      highlight: highlight,
      highlightColor: highlightColor,
      isModerator: mod,
      isOwner: owner,
      color: owner
          ? const Color(0xFFFFD600)
          : mod
          ? const Color(0xFF5E84F1)
          : isMember
          ? const Color(0xFF2BA640)
          : verified
          ? const Color(0xFFE0E0E0)
          : null,
    );
  }

  static String _text(Object? node) {
    if (node is! Map) return '';
    if (node['simpleText'] is String) return node['simpleText'] as String;
    return [for (final r in (node['runs'] as List? ?? const [])) (r as Map)['text'] ?? ''].join();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _viewerTimer?.cancel();
    _http.close();
    chat.dispose();
    _viewers.dispose();
  }
}
