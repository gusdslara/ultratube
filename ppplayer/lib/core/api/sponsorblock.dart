import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// One skippable range reported by the SponsorBlock community database.
class SkipSegment {
  const SkipSegment(this.start, this.end, this.category);
  final Duration start;
  final Duration end;
  final String category;

  String get label => switch (category) {
    'sponsor' => 'Patrocínio',
    'selfpromo' => 'Autopromoção',
    'interaction' => 'Pedido de inscrição',
    'music_offtopic' => 'Trecho sem música',
    'intro' => 'Introdução',
    'outro' => 'Encerramento',
    _ => 'Trecho',
  };
}

/// Privacy-preserving SponsorBlock client: only the first 4 hex chars of the
/// video id's SHA-256 leave the device (k-anonymity endpoint).
class SponsorBlock {
  const SponsorBlock({http.Client? client}) : _client = client; // ignore: prefer_initializing_formals
  final http.Client? _client;

  static const categories = [
    'sponsor',
    'selfpromo',
    'interaction',
    'music_offtopic',
  ];

  Future<List<SkipSegment>> segments(String videoId) async {
    final prefix = sha256
        .convert(utf8.encode(videoId))
        .toString()
        .substring(0, 4);
    final uri = Uri.https('sponsor.ajay.app', '/api/skipSegments/$prefix', {
      'categories': jsonEncode(categories),
    });
    final client = _client ?? http.Client();
    try {
      final response = await client
          .get(uri, headers: {'User-Agent': 'Ultratube'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 404) return const [];
      if (response.statusCode != 200) return const [];
      return parse(response.body, videoId);
    } finally {
      if (_client == null) client.close();
    }
  }

  static List<SkipSegment> parse(String body, String videoId) {
    final videos = jsonDecode(body) as List;
    final match = videos.cast<Map>().where((v) => v['videoID'] == videoId);
    if (match.isEmpty) return const [];
    final result = <SkipSegment>[];
    for (final raw in (match.first['segments'] as List? ?? const [])) {
      final segment = raw as Map;
      final range = (segment['segment'] as List).cast<num>();
      if ((segment['actionType'] ?? 'skip') != 'skip') continue;
      final start = Duration(milliseconds: (range[0] * 1000).round());
      final end = Duration(milliseconds: (range[1] * 1000).round());
      if (end - start < const Duration(seconds: 1)) continue;
      result.add(SkipSegment(start, end, segment['category'] as String));
    }
    result.sort((a, b) => a.start.compareTo(b.start));
    return result;
  }
}
