import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/yt_models.dart';
import '../../core/player/player_provider.dart';
import '../../core/services/settings_provider.dart';
import '../../core/theme/ultratube_theme.dart';
import '../../core/ultratube/ultratube_store.dart';
import '../live/live_chat_view.dart';
import 'pip_button.dart';
import 'playlist_picker.dart';
import 'queue_sheet.dart';

/// Tabs of the video menu, in display order.
enum VideoMenuTab { options, queue, playlist }

/// Turns "Só áudio" on or off for every video (re-resolves the current one
/// at the same position: audio only streams just the audio track).
void toggleAudioOnly(BuildContext context, WidgetRef ref) {
  HapticFeedback.selectionClick();
  final next = !ref.read(audioOnlyProvider);
  ref.read(audioOnlyProvider.notifier).set(next);
  ref.read(settingsProvider.notifier).setPlayerView(next ? PlayerView.artwork : PlayerView.video);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(next ? 'Só áudio: a imagem não é baixada' : 'Vídeo ligado'), duration: const Duration(seconds: 2)));
}

/// Video menu opened by dragging the video down (or the gear button):
/// options (quality, speed, audio, autoplay…), the queue and "Salvar em".
Future<void> showVideoMenu(BuildContext context, {required YtItem? item, bool live = false, VideoMenuTab initial = VideoMenuTab.options}) {
  HapticFeedback.lightImpact();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: UT.surface1,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (sheet) => SizedBox(
      height: MediaQuery.sizeOf(sheet).height * 0.72,
      child: _VideoMenu(item: item, live: live, initial: initial),
    ),
  );
}

class _VideoMenu extends StatelessWidget {
  const _VideoMenu({required this.item, required this.live, required this.initial});
  final YtItem? item;
  final bool live;
  final VideoMenuTab initial;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    return DefaultTabController(
      length: VideoMenuTab.values.length,
      initialIndex: initial.index,
      child: Column(
        children: [
          const TabBar(
            indicatorColor: UT.red,
            labelColor: UT.text,
            unselectedLabelColor: UT.text2,
            dividerColor: Colors.transparent,
            tabs: [
              Tab(icon: Icon(Icons.tune_rounded, size: 20), text: 'Opções'),
              Tab(icon: Icon(Icons.queue_music, size: 20), text: 'Fila'),
              Tab(icon: Icon(Icons.playlist_add, size: 20), text: 'Playlist'),
            ],
          ),
          const SizedBox(height: UT.s2),
          Expanded(
            child: TabBarView(
              children: [
                _Options(live: live),
                const QueueView(),
                if (item == null)
                  const Center(
                    child: Text('Carregando o vídeo…', style: TextStyle(color: UT.text2)),
                  )
                else
                  PlaylistPicker(item: item, shrinkWrap: false, closeOnCreate: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Options extends ConsumerWidget {
  const _Options({required this.live});
  final bool live;

  static const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  String _speedLabel(double s) => s == 1.0 ? 'Normal' : '${s.toString().replaceAll('.', ',')}x';

  Future<T?> _pick<T>(BuildContext context, String title, List<T> values, T current, String Function(T) label) => showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    backgroundColor: UT.surface1,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(UT.s5, 0, UT.s5, UT.s2),
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final v in values)
              ListTile(
                leading: Icon(v == current ? Icons.check : null, color: UT.red),
                title: Text(label(v)),
                onTap: () => Navigator.pop(sheet, v),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = ref.watch(videoQualityProvider);
    final audioQuality = ref.watch(audioQualityProvider);
    final speed = ref.watch(playerProvider.select((s) => s.speed));
    final audioOnly = ref.watch(audioOnlyProvider);
    final autoplay = ref.watch(ultratubeAutoplayProvider);
    final sponsor = ref.watch(sponsorSkipProvider);
    String q(int h) => h >= 2160 ? '${h}p 4K' : '${h}p';

    Widget entry(IconData icon, String title, String value, VoidCallback onTap) => ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(color: UT.text2)),
          const Icon(Icons.chevron_right, color: UT.text3),
        ],
      ),
      onTap: onTap,
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: UT.s6),
      children: [
        entry(Icons.high_quality_outlined, 'Qualidade', q(quality), () async {
          final v = await _pick<int>(context, 'Qualidade do vídeo', VideoQualityNotifier.options.reversed.toList(), quality, q);
          if (v != null) ref.read(videoQualityProvider.notifier).set(v);
        }),
        entry(Icons.graphic_eq, 'Qualidade do áudio', AudioQualityNotifier.label(audioQuality), () async {
          final v = await _pick<String>(context, 'Qualidade do áudio', AudioQualityNotifier.options, audioQuality, AudioQualityNotifier.label);
          if (v != null) ref.read(audioQualityProvider.notifier).set(v);
        }),
        if (!live)
          entry(Icons.speed, 'Velocidade', _speedLabel(speed), () async {
            final v = await _pick<double>(context, 'Velocidade', _speeds, speed, _speedLabel);
            if (v != null) ref.read(playerProvider.notifier).setSpeed(v);
          }),
        SwitchListTile(
          secondary: const Icon(Icons.headphones_outlined),
          title: const Text('Só áudio'),
          subtitle: const Text('Não baixa a imagem'),
          value: audioOnly,
          onChanged: (_) => toggleAudioOnly(context, ref),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.play_circle_outline),
          title: const Text('Reprodução automática'),
          value: autoplay,
          onChanged: ref.read(ultratubeAutoplayProvider.notifier).set,
        ),
        if (!live)
          SwitchListTile(
            secondary: const Icon(Icons.fast_forward_outlined),
            title: const Text('Pular patrocínios'),
            subtitle: const Text('SponsorBlock'),
            value: sponsor,
            onChanged: ref.read(sponsorSkipProvider.notifier).set,
          ),
        if (live) ListTile(leading: const Icon(Icons.chat_outlined), title: const Text('Ajustes do chat ao vivo'), onTap: () => showLiveChatSettings(context)),
        if (pipSupported)
          ListTile(
            leading: const Icon(Icons.picture_in_picture_alt_outlined),
            title: const Text('Janela flutuante'),
            onTap: () {
              Navigator.pop(context);
              enterVideoPip(ref);
            },
          ),
      ],
    );
  }
}
