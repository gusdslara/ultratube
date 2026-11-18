import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/yt_models.dart';
import '../../core/downloads/ultratube_downloads.dart';
import '../../core/player/player_provider.dart';
import '../../core/theme/ultratube_theme.dart';
import '../ultratube/playlist_picker.dart';

/// ⋮ for a video: opens a YouTube-style action sheet.
class TrackActionsButton extends ConsumerWidget {
  const TrackActionsButton({super.key, required this.track, this.item, this.color});

  final Track track;
  final YtItem? item;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: 'Mais opções',
    visualDensity: VisualDensity.compact,
    icon: Icon(Icons.more_vert, color: color ?? UT.text2, size: 20),
    onPressed: () => showVideoActions(context, ref, track: track, item: item),
  );
}

Future<void> showVideoActions(BuildContext context, WidgetRef ref, {required Track track, YtItem? item}) {
  final video = item ?? (track.youtubeVideoId != null ? YtItem.fromTrack(track) : null);
  void notice(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  return showModalBottomSheet<void>(
    context: context,
    builder: (sheet) {
      Widget action(IconData icon, String label, VoidCallback onTap) => ListTile(
        leading: Icon(icon),
        title: Text(label, style: const TextStyle(fontSize: 15)),
        onTap: () {
          Navigator.pop(sheet);
          onTap();
        },
      );
      final player = ref.read(playerProvider.notifier);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            action(Icons.queue_play_next, 'Tocar em seguida', () {
              player.playNext(track);
              notice('Toca em seguida');
            }),
            action(Icons.playlist_add, 'Adicionar à fila', () {
              player.addToQueue(track);
              notice('Adicionado à fila');
            }),
            if (video != null) action(Icons.bookmark_add_outlined, 'Salvar em playlist', () => showAddToPlaylist(context, video)),
            if (UltratubeDownloads.supported && track.youtubeVideoId != null)
              action(Icons.download_outlined, 'Baixar', () => showDownloadOptions(context, track)),
            if (track.youtubeVideoId != null)
              action(Icons.share_outlined, 'Compartilhar', () {
                Clipboard.setData(ClipboardData(text: 'https://youtu.be/${track.youtubeVideoId}'));
                notice('Link copiado');
              }),
            if (video != null && video.channelUrl.isNotEmpty)
              action(Icons.account_circle_outlined, 'Ir para o canal', () {
                context.push('/channel?url=${Uri.encodeComponent(video.channelUrl)}', extra: video.channel);
              }),
          ],
        ),
      );
    },
  );
}

Future<void> showDownloadOptions(BuildContext context, Track track) => showModalBottomSheet<void>(
  context: context,
  builder: (sheet) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(UT.s5, 0, UT.s5, UT.s2),
          child: Text('Baixar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        for (final (icon, label, sub, video, height) in [
          (Icons.music_note_outlined, 'Áudio', 'M4A, melhor qualidade', false, 1080),
          (Icons.sd_outlined, 'Vídeo 480p', 'Economiza espaço', true, 480),
          (Icons.movie_outlined, 'Vídeo 720p', 'HD', true, 720),
          (Icons.hd_outlined, 'Vídeo 1080p', 'Full HD', true, 1080),
        ])
          ListTile(
            leading: Icon(icon),
            title: Text(label),
            subtitle: Text(sub),
            onTap: () {
              Navigator.pop(sheet);
              startDownload(track, video: video, maxHeight: height);
            },
          ),
      ],
    ),
  ),
);
