import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import '../live/live_chat.dart';
import 'twitch_api.dart';

/// Read-only Twitch chat over IRC-over-WebSocket as an anonymous
/// "justinfan" user (no login), with Twitch, 7TV and BTTV emotes and
/// badges, plus the viewer count polled from GraphQL.
class TwitchLiveSession implements LiveSession {
  TwitchLiveSession(this.login, {TwitchApi? api}) : _api = api ?? TwitchApi.instance {
    unawaited(_loadExtras());
    _connect();
    _pollViewers();
    _viewerTimer = Timer.periodic(const Duration(seconds: 30), (_) => _pollViewers());
  }

  final String login;
  final TwitchApi _api;
  final _http = http.Client();
  @override
  final ChatFeed chat = ChatFeed(limit: 300);
  final _viewers = ValueNotifier<int>(-1);
  @override
  ValueListenable<int> get viewers => _viewers;

  /// Fresh title/category, refreshed with the viewer count.
  final stream = ValueNotifier<TwitchStream?>(null);

  WebSocket? _socket;
  Timer? _viewerTimer;
  Timer? _reconnect;
  bool _disposed = false;
  int _attempt = 0;
  String? _roomId;

  /// "setId/version" → image.
  final _badges = <String, String>{};

  /// Third-party emote code → image (7TV + BTTV, channel then global).
  final _emotes = <String, String>{};

  static const _palette = [
    Color(0xFFFF4A80), Color(0xFF00C2FF), Color(0xFF9E9EFF), Color(0xFF2CC48E),
    Color(0xFFFF9F43), Color(0xFFB98AFF), Color(0xFFFFD166), Color(0xFF5BD1FF),
  ];

  void _connect() {
    if (_disposed) return;
    chat.setState(connected: false);
    WebSocket.connect('wss://irc-ws.chat.twitch.tv:443').timeout(const Duration(seconds: 15)).then((socket) {
      if (_disposed) {
        socket.close();
        return;
      }
      _socket = socket;
      final nick = 'justinfan${10000 + Random().nextInt(89999)}';
      socket
        ..add('CAP REQ :twitch.tv/tags twitch.tv/commands')
        ..add('PASS SCHMOOPIIE')
        ..add('NICK $nick')
        ..add('JOIN #${login.toLowerCase()}');
      socket.listen(
        (data) => _onData('$data'),
        onDone: _scheduleReconnect,
        onError: (Object _) => _scheduleReconnect(),
        cancelOnError: true,
      );
    }).catchError((Object _) {
      _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _socket = null;
    chat.setState(connected: false);
    _reconnect?.cancel();
    final delay = Duration(seconds: min(30, 2 << min(_attempt++, 4)));
    _reconnect = Timer(delay, _connect);
  }

  void _onData(String data) {
    final batch = <ChatMessage>[];
    for (final line in const LineSplitter().convert(data)) {
      if (line.isEmpty) continue;
      if (line.startsWith('PING')) {
        _socket?.add('PONG :tmi.twitch.tv');
        continue;
      }
      final msg = _IrcLine.parse(line);
      if (msg == null) continue;
      switch (msg.command) {
        case 'ROOMSTATE':
          final id = msg.tags['room-id'];
          if (id != null && id != _roomId) {
            _roomId = id;
            unawaited(_loadChannelEmotes(id));
          }
        case 'JOIN':
        case '366':
          _attempt = 0;
          if (!chat.connected) chat.setState(connected: true, clearError: true);
        case 'PRIVMSG':
          final m = _message(msg);
          if (m != null) batch.add(m);
        case 'USERNOTICE':
          final m = _notice(msg);
          if (m != null) batch.add(m);
        case 'CLEARCHAT':
          // Ban/timeout: hide that user's lines (or everything on a clear).
          final user = msg.trailing;
          if (user == null || user.isEmpty) {
            chat.messages.clear();
          } else {
            chat.messages.removeWhere((m) => m.author.toLowerCase() == user.toLowerCase());
          }
          chat.setState();
        case 'CLEARMSG':
          final id = msg.tags['target-msg-id'];
          chat.messages.removeWhere((m) => m.id == id);
          chat.setState();
        case 'RECONNECT':
          _socket?.close();
        case 'NOTICE':
          if ((msg.tags['msg-id'] ?? '').contains('ban') || (msg.trailing ?? '').contains('suspended')) {
            chat.setState(error: 'Chat indisponível: ${msg.trailing}');
          }
      }
    }
    chat.addAll(batch);
  }

  ChatMessage? _message(_IrcLine msg) {
    final text = msg.trailing ?? '';
    final tags = msg.tags;
    var body = text;
    var action = false;
    // "/me" messages arrive wrapped in CTCP ACTION.
    if (body.startsWith('\u0001ACTION ') && body.endsWith('\u0001')) {
      body = body.substring(8, body.length - 1);
      action = true;
    }
    final name = tags['display-name']?.isNotEmpty == true ? tags['display-name']! : (msg.nick ?? '');
    final bits = int.tryParse(tags['bits'] ?? '');
    return ChatMessage(
      id: tags['id'] ?? '${DateTime.now().microsecondsSinceEpoch}',
      author: name,
      parts: _parts(body, tags['emotes'], italic: action),
      color: _color(tags['color'], name),
      badges: _badgeImages(tags['badges']),
      isModerator: (tags['badges'] ?? '').contains('moderator/'),
      isOwner: (tags['badges'] ?? '').contains('broadcaster/'),
      highlight: bits != null && bits > 0 ? '$bits bits' : null,
      highlightColor: bits != null && bits > 0 ? const Color(0xFF9146FF) : null,
    );
  }

  ChatMessage? _notice(_IrcLine msg) {
    final tags = msg.tags;
    final system = (tags['system-msg'] ?? '').replaceAll(r'\s', ' ').trim();
    if (system.isEmpty && (msg.trailing ?? '').isEmpty) return null;
    final name = tags['display-name'] ?? tags['login'] ?? '';
    return ChatMessage(
      id: tags['id'] ?? '${DateTime.now().microsecondsSinceEpoch}',
      author: msg.trailing == null ? '' : name,
      parts: msg.trailing == null ? const [] : _parts(msg.trailing!, tags['emotes']),
      color: _color(tags['color'], name),
      badges: _badgeImages(tags['badges']),
      highlight: system.isEmpty ? 'Aviso' : system,
      highlightColor: const Color(0xFF9146FF),
    );
  }

  /// Splits the text into text/emote parts. Twitch emote ranges index
  /// Unicode code points, not UTF-16 units.
  List<ChatPart> _parts(String text, String? emoteTag, {bool italic = false}) {
    final runes = text.runes.toList();
    final ranges = <(int, int, String)>[];
    if (emoteTag != null && emoteTag.isNotEmpty) {
      for (final group in emoteTag.split('/')) {
        final colon = group.indexOf(':');
        if (colon < 0) continue;
        final id = group.substring(0, colon);
        for (final r in group.substring(colon + 1).split(',')) {
          final dash = r.indexOf('-');
          final a = int.tryParse(r.substring(0, max(dash, 0)));
          final b = int.tryParse(r.substring(dash + 1));
          if (a != null && b != null && b < runes.length) ranges.add((a, b, id));
        }
      }
      ranges.sort((x, y) => x.$1.compareTo(y.$1));
    }
    final parts = <ChatPart>[];
    var i = 0;
    for (final (a, b, id) in ranges) {
      if (a < i) continue;
      if (a > i) parts.addAll(_thirdParty(String.fromCharCodes(runes.sublist(i, a))));
      parts.add(ChatPart.emote('https://static-cdn.jtvnw.net/emoticons/v2/$id/default/dark/2.0', text: String.fromCharCodes(runes.sublist(a, b + 1))));
      i = b + 1;
    }
    if (i < runes.length) parts.addAll(_thirdParty(String.fromCharCodes(runes.sublist(i))));
    return parts;
  }

  /// Replaces 7TV/BTTV emote words inside a plain text run.
  List<ChatPart> _thirdParty(String text) {
    if (_emotes.isEmpty) return [ChatPart.text(text)];
    final out = <ChatPart>[];
    final buf = StringBuffer();
    for (final token in text.split(RegExp(r'(?<= )|(?= )'))) {
      final url = _emotes[token];
      if (url != null) {
        if (buf.isNotEmpty) {
          out.add(ChatPart.text(buf.toString()));
          buf.clear();
        }
        out.add(ChatPart.emote(url, text: token));
      } else {
        buf.write(token);
      }
    }
    if (buf.isNotEmpty) out.add(ChatPart.text(buf.toString()));
    return out;
  }

  List<String> _badgeImages(String? tag) {
    if (tag == null || tag.isEmpty || _badges.isEmpty) return const [];
    return [
      for (final b in tag.split(','))
        if (_badges[b] ?? _badges['${b.split('/').first}/1'] case final url?) url,
    ].take(3).toList();
  }

  static Color _color(String? hex, String name) {
    if (hex != null && hex.length == 7 && hex.startsWith('#')) {
      final c = Color(int.parse('FF${hex.substring(1)}', radix: 16));
      // Lift very dark name colours so they stay readable over video.
      return c.computeLuminance() < 0.08 ? Color.lerp(c, const Color(0xFFFFFFFF), 0.45)! : c;
    }
    return _palette[name.hashCode.abs() % _palette.length];
  }

  // -------------------------------------------------------------- extras

  Future<void> _loadExtras() async {
    // Global Twitch badges + channel badges in one request.
    try {
      final res = await _http.post(
        Uri.parse('https://gql.twitch.tv/gql'),
        headers: {'Client-ID': TwitchApi.clientId, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'query': 'query(\$login: String!) { badges { setID version imageURL(size: DOUBLE) } '
              'user(login: \$login) { id broadcastBadges { setID version imageURL(size: DOUBLE) } } }',
          'variables': {'login': login.toLowerCase()},
        }),
      );
      final data = (jsonDecode(res.body) as Map)['data'] as Map?;
      for (final b in [...(data?['badges'] as List? ?? const []), ...(data?['user']?['broadcastBadges'] as List? ?? const [])]) {
        final m = b as Map;
        _badges['${m['setID']}/${m['version']}'] = m['imageURL'] as String;
      }
      final id = data?['user']?['id'] as String?;
      if (id != null && _roomId == null) {
        _roomId = id;
        await _loadChannelEmotes(id);
      }
    } catch (_) {}
    await _loadGlobalEmotes();
  }

  Future<void> _loadGlobalEmotes() async {
    try {
      final res = await _http.get(Uri.parse('https://7tv.io/v3/emote-sets/global')).timeout(const Duration(seconds: 15));
      _add7tv((jsonDecode(res.body) as Map)['emotes'] as List?, overwrite: false);
    } catch (_) {}
    try {
      final res = await _http.get(Uri.parse('https://api.betterttv.net/3/cached/emotes/global')).timeout(const Duration(seconds: 15));
      _addBttv(jsonDecode(res.body) as List?, overwrite: false);
    } catch (_) {}
  }

  Future<void> _loadChannelEmotes(String twitchId) async {
    try {
      final res = await _http.get(Uri.parse('https://7tv.io/v3/users/twitch/$twitchId')).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) _add7tv((jsonDecode(res.body) as Map)['emote_set']?['emotes'] as List?, overwrite: true);
    } catch (_) {}
    try {
      final res = await _http.get(Uri.parse('https://api.betterttv.net/3/cached/users/twitch/$twitchId')).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final m = jsonDecode(res.body) as Map;
        _addBttv([...(m['channelEmotes'] as List? ?? const []), ...(m['sharedEmotes'] as List? ?? const [])], overwrite: true);
      }
    } catch (_) {}
  }

  void _add7tv(List? emotes, {required bool overwrite}) {
    for (final e in emotes ?? const []) {
      final m = e as Map;
      final name = m['name'] as String?;
      final host = m['data']?['host']?['url'] as String?;
      if (name == null || host == null) continue;
      if (!overwrite && _emotes.containsKey(name)) continue;
      _emotes[name] = '${host.startsWith('//') ? 'https:$host' : host}/2x.webp';
    }
  }

  void _addBttv(List? emotes, {required bool overwrite}) {
    for (final e in emotes ?? const []) {
      final m = e as Map;
      final code = m['code'] as String?;
      final id = m['id'] as String?;
      if (code == null || id == null) continue;
      if (!overwrite && _emotes.containsKey(code)) continue;
      _emotes[code] = 'https://cdn.betterttv.net/emote/$id/2x';
    }
  }

  Future<void> _pollViewers() async {
    try {
      final info = await _api.liveInfo(login);
      if (_disposed) return;
      stream.value = info;
      _viewers.value = info?.viewers ?? -1;
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _viewerTimer?.cancel();
    _reconnect?.cancel();
    _socket?.close();
    _http.close();
    chat.dispose();
    _viewers.dispose();
    stream.dispose();
  }
}

/// One IRC line: `@tags :prefix COMMAND params :trailing`.
class _IrcLine {
  const _IrcLine(this.tags, this.nick, this.command, this.trailing);
  final Map<String, String> tags;
  final String? nick;
  final String command;
  final String? trailing;

  static _IrcLine? parse(String line) {
    var rest = line;
    final tags = <String, String>{};
    if (rest.startsWith('@')) {
      final space = rest.indexOf(' ');
      if (space < 0) return null;
      for (final kv in rest.substring(1, space).split(';')) {
        final eq = kv.indexOf('=');
        if (eq < 0) continue;
        tags[kv.substring(0, eq)] = kv
            .substring(eq + 1)
            .replaceAll(r'\s', ' ')
            .replaceAll(r'\:', ';')
            .replaceAll(r'\\', '\\');
      }
      rest = rest.substring(space + 1);
    }
    String? nick;
    if (rest.startsWith(':')) {
      final space = rest.indexOf(' ');
      if (space < 0) return null;
      final prefix = rest.substring(1, space);
      final bang = prefix.indexOf('!');
      nick = bang > 0 ? prefix.substring(0, bang) : prefix;
      rest = rest.substring(space + 1);
    }
    final colon = rest.indexOf(' :');
    final head = colon >= 0 ? rest.substring(0, colon) : rest;
    final trailing = colon >= 0 ? rest.substring(colon + 2) : null;
    final command = head.split(' ').first;
    return _IrcLine(tags, nick, command, trailing);
  }
}
