import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/ultratube_catalog.dart';
import '../../core/player/player_provider.dart';
import '../../core/services/settings_provider.dart';
import '../downloads/track_actions_button.dart';

/// Android's direct YouTube catalog. No Spotify account or API key required.
class UltratubeSearchScreen extends ConsumerStatefulWidget {
  const UltratubeSearchScreen({super.key});
  @override
  ConsumerState<UltratubeSearchScreen> createState() =>
      _UltratubeSearchScreenState();
}

class _UltratubeSearchScreenState extends ConsumerState<UltratubeSearchScreen> {
  final _query = TextEditingController();
  List<Track> _results = [];
  bool _music = true;
  bool _busy = false;
  bool _searched = false;
  String? _error;
  int _generation = 0;
  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _searched = true;
    });
    try {
      final results = await const UltratubeCatalog().search(
        query,
        music: _music,
      );
      if (mounted && generation == _generation)
        setState(() => _results = results);
    } catch (error) {
      if (mounted && generation == _generation)
        setState(
          () => _error =
              'Não foi possível buscar. Verifique sua conexão e tente novamente.\n$error',
        );
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _play(Track track) async {
    await ref
        .read(settingsProvider.notifier)
        .setPlayerView(_music ? PlayerView.artwork : PlayerView.video);
    if (!mounted) return;
    final player = ref.read(playerProvider.notifier);
    context.push('/player');
    await player.playTrack(track, queue: _results);
  }

  @override
  void dispose() {
    ++_generation;
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ULTRATUBE',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 4,
                      fontWeight: FontWeight.bold,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Dê o play.\nDo seu jeito.',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Músicas, vídeos e seus Shorts em um só lugar.',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: _music
                          ? 'Música, artista ou álbum'
                          : 'Buscar no YouTube',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        onPressed: _search,
                        tooltip: 'Buscar',
                        icon: const Icon(Icons.arrow_forward),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Músicas'),
                        selected: _music,
                        onSelected: (_) {
                          setState(() => _music = true);
                          _search();
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Vídeos'),
                        selected: !_music,
                        onSelected: (_) {
                          setState(() => _music = false);
                          _search();
                        },
                      ),
                      ActionChip(
                        label: const Text('Shorts'),
                        avatar: const Icon(Icons.slow_motion_video, size: 18),
                        onPressed: () => context.go('/shorts'),
                      ),
                    ],
                  ),
                  if (!_searched) ...[
                    const SizedBox(height: 28),
                    const Text(
                      'Encontre seu próximo som',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children:
                          [
                                'MPB',
                                'Lo-fi',
                                'Rock brasileiro',
                                'Jazz',
                                'Clássica',
                              ]
                              .map(
                                (label) => ActionChip(
                                  label: Text(label),
                                  onPressed: () {
                                    _query.text = label;
                                    _search();
                                  },
                                ),
                              )
                              .toList(),
                    ),
                  ],
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 20),
                      child: LinearProgressIndicator(),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                  if (!_busy && _searched && _results.isEmpty && _error == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: Text('Nenhum resultado. Experimente outro nome.'),
                    ),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: _busy ? 0 : _results.length,
            itemBuilder: (context, i) {
              final track = _results[i];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    track.albumImage ?? '',
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (_, e, s) => const SizedBox(
                      width: 64,
                      height: 64,
                      child: Icon(Icons.music_note),
                    ),
                  ),
                ),
                title: Text(
                  track.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  track.artistName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TrackActionsButton(track: track),
                onTap: () => _play(track),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }
}
