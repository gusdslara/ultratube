import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../core/player/player_provider.dart';
import '../../core/playback/playback_providers.dart';
import 'ultratube_lrc.dart';

final _lyrics = FutureProvider.autoDispose
    .family<Map<String, dynamic>, (String, String)>((ref, key) async {
      final client = http.Client();
      ref.onDispose(client.close);
      final response = await client
          .get(
            Uri.https('lrclib.net', '/api/get', {
              'track_name': key.$1,
              'artist_name': key.$2,
            }),
            headers: {'User-Agent': 'Ultratube/0.1.0'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 404)
        return {'plainLyrics': 'Letra não encontrada para esta faixa.'};
      if (response.statusCode != 200)
        throw StateError(
          'Serviço de letras indisponível (${response.statusCode})',
        );
      return jsonDecode(response.body) as Map<String, dynamic>;
    });

void showUltratubeLyrics(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) =>
      const FractionallySizedBox(heightFactor: .85, child: UltratubeLyrics()),
);

class UltratubeLyrics extends ConsumerStatefulWidget {
  const UltratubeLyrics({super.key});
  @override
  ConsumerState<UltratubeLyrics> createState() => _UltratubeLyricsState();
}

class _UltratubeLyricsState extends ConsumerState<UltratubeLyrics> {
  final _scroll = ScrollController();
  int _lastLine = -1;
  String? _trackId;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(playerProvider.select((s) => s.currentTrack));
    final seconds = ref.watch(
      playerProvider.select((s) => s.position.inSeconds),
    );
    if (track == null)
      return const Center(child: Text('Escolha uma música para ver a letra.'));
    if (_trackId != track.spotifyId) {
      _trackId = track.spotifyId;
      _lastLine = -1;
    }
    final key = (track.name, track.artistName);
    return Column(
      children: [
        ListTile(
          title: Text(track.name, maxLines: 2),
          subtitle: Text('${track.artistName} · Letras: LRCLIB'),
          trailing: IconButton(
            tooltip: 'Fechar letras',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ),
        Expanded(
          child: ref
              .watch(_lyrics(key))
              .when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Não foi possível carregar a letra.'),
                      TextButton(
                        onPressed: () => ref.invalidate(_lyrics(key)),
                        child: const Text('Tentar novamente'),
                      ),
                    ],
                  ),
                ),
                data: (data) {
                  if (data['instrumental'] == true)
                    return const Center(child: Text('Faixa instrumental'));
                  final lines = parseUltratubeLrc(
                    data['syncedLyrics'] as String? ?? '',
                  );
                  if (lines.isEmpty)
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: SelectableText(
                        data['plainLyrics'] as String? ?? 'Letra indisponível',
                        style: const TextStyle(fontSize: 22, height: 1.7),
                      ),
                    );
                  var active = -1;
                  for (var i = 0; i < lines.length; i++) {
                    if (lines[i].time.inSeconds <= seconds) active = i;
                  }
                  if (active != _lastLine) {
                    _lastLine = active;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _scroll.hasClients && active >= 0)
                        _scroll.animateTo(
                          (active * 88.0 - 88).clamp(
                            0,
                            _scroll.position.maxScrollExtent,
                          ),
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOut,
                        );
                    });
                  }
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 24,
                    ),
                    itemExtent: 88,
                    itemCount: lines.length,
                    itemBuilder: (context, i) => InkWell(
                      onTap: () => ref
                          .read(playbackControllerProvider)
                          .seekTo(lines[i].time),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          lines[i].text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: i == active
                                ? FontWeight.w800
                                : FontWeight.w400,
                            color: i == active
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
        ),
      ],
    );
  }
}
