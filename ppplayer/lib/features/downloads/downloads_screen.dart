import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/downloads/ultratube_downloads.dart';
import '../../core/player/player_provider.dart';
import '../../core/services/settings_provider.dart';

enum _Filter { all, audio, video }

/// Offline library of Ultratube downloads with live progress.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  _Filter _filter = _Filter.all;

  List<DownloadJob> _visible(List<DownloadJob> jobs) => switch (_filter) {
    _Filter.all => jobs,
    _Filter.audio => jobs.where((j) => !j.video).toList(),
    _Filter.video => jobs.where((j) => j.video).toList(),
  };

  Future<void> _play(DownloadJob job, List<DownloadJob> jobs) async {
    final notifier = ref.read(downloadsProvider.notifier);
    final ready = jobs
        .where((j) => j.state == DownloadState.done && j.video == job.video)
        .toList();
    final tracks = [
      for (final j in ready)
        if (await notifier.trackFor(j) case final track?) track,
    ];
    final selected = await notifier.trackFor(job);
    if (!mounted) return;
    if (selected == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Arquivo não encontrado. Baixe novamente.')),
      );
      return;
    }
    await ref
        .read(settingsProvider.notifier)
        .setPlayerView(job.video ? PlayerView.video : PlayerView.artwork);
    if (!mounted) return;
    context.push('/player');
    final queue = tracks.isEmpty ? [selected] : tracks;
    await ref
        .read(playerProvider.notifier)
        .playTrack(
          queue.firstWhere(
            (t) => t.localFilePath == selected.localFilePath,
            orElse: () => selected,
          ),
          queue: queue,
        );
  }

  Future<void> _confirmRemove(DownloadJob job) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover download?'),
        content: Text(
          job.state == DownloadState.done
              ? '"${job.title}" será apagado deste aparelho.'
              : 'O download de "${job.title}" será cancelado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Manter'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (remove == true) await const UltratubeDownloads().remove(job.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final downloads = ref.watch(downloadsProvider);
    final jobs = downloads.value ?? const <DownloadJob>[];
    final visible = _visible(jobs);
    final totalBytes = jobs.fold<int>(0, (sum, j) => sum + (j.size ?? 0));
    final doneCount = jobs.where((j) => j.state == DownloadState.done).length;

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          const SliverAppBar(floating: true, title: Text('Downloads')),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doneCount == 0
                        ? 'Sem anúncios e sem internet: baixe músicas e vídeos pelo menu de cada resultado.'
                        : '$doneCount ${doneCount == 1 ? 'item' : 'itens'} · ${_formatBytes(totalBytes)} neste aparelho',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<_Filter>(
                    segments: const [
                      ButtonSegment(value: _Filter.all, label: Text('Tudo')),
                      ButtonSegment(
                        value: _Filter.audio,
                        label: Text('Áudio'),
                        icon: Icon(Icons.music_note_outlined),
                      ),
                      ButtonSegment(
                        value: _Filter.video,
                        label: Text('Vídeo'),
                        icon: Icon(Icons.movie_outlined),
                      ),
                    ],
                    selected: {_filter},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => setState(() => _filter = s.first),
                  ),
                ],
              ),
            ),
          ),
          if (downloads.isLoading && jobs.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: LinearProgressIndicator(),
              ),
            )
          else if (downloads.hasError)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Não foi possível ler os downloads.\n${downloads.error}',
                  style: TextStyle(color: colors.error),
                ),
              ),
            )
          else if (visible.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(filter: _filter),
            )
          else
            SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, i) => _DownloadTile(
                job: visible[i],
                onPlay: () => _play(visible[i], jobs),
                onRemove: () => _confirmRemove(visible[i]),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({
    required this.job,
    required this.onPlay,
    required this.onRemove,
  });

  final DownloadJob job;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const api = UltratubeDownloads();
    final subtitle = switch (job.state) {
      DownloadState.queued => 'Na fila',
      DownloadState.running => 'Baixando ${(job.progress * 100).round()}%',
      DownloadState.done => [
        job.artist,
        if (job.resolution != null) job.resolution!,
        if (job.size != null) _formatBytes(job.size!),
      ].where((s) => s.isNotEmpty).join(' · '),
      DownloadState.failed => 'Falhou: ${job.error ?? 'erro desconhecido'}',
      DownloadState.canceled => 'Cancelado',
    };

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      enabled: job.state == DownloadState.done,
      onTap: job.state == DownloadState.done ? onPlay : null,
      leading: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 64,
              height: 64,
              child: job.coverFile != null
                  ? Image.file(
                      File(job.coverFile!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, e, s) => _fallbackCover(job),
                    )
                  : Image.network(
                      job.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, e, s) => _fallbackCover(job),
                    ),
            ),
          ),
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                job.video ? Icons.movie_outlined : Icons.music_note_outlined,
                size: 14,
              ),
            ),
          ),
        ],
      ),
      title: Text(job.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: job.state == DownloadState.failed
                ? TextStyle(color: colors.error)
                : null,
          ),
          if (job.active)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(
                value: job.state == DownloadState.running && job.progress > 0
                    ? job.progress
                    : null,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
      trailing: switch (job.state) {
        DownloadState.queued || DownloadState.running => IconButton(
          tooltip: 'Cancelar',
          icon: const Icon(Icons.close),
          onPressed: () => api.cancel(job.id),
        ),
        DownloadState.failed || DownloadState.canceled => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Tentar de novo',
              icon: const Icon(Icons.refresh),
              onPressed: () => api.retry(job.id),
            ),
            IconButton(
              tooltip: 'Remover',
              icon: const Icon(Icons.delete_outline),
              onPressed: onRemove,
            ),
          ],
        ),
        DownloadState.done => IconButton(
          tooltip: 'Apagar do aparelho',
          icon: const Icon(Icons.delete_outline),
          onPressed: onRemove,
        ),
      },
    );
  }

  Widget _fallbackCover(DownloadJob job) => ColoredBox(
    color: Colors.black26,
    child: Icon(job.video ? Icons.movie_outlined : Icons.music_note),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filter});
  final _Filter filter;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.download_for_offline_outlined, size: 56, color: colors.primary),
          const SizedBox(height: 16),
          Text(
            switch (filter) {
              _Filter.all => 'Nada baixado ainda',
              _Filter.audio => 'Nenhum áudio baixado',
              _Filter.video => 'Nenhum vídeo baixado',
            },
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Na busca, toque em ⋮ ao lado de um resultado e escolha "Baixar áudio" ou "Baixar vídeo".',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: () => context.go('/home'),
            icon: const Icon(Icons.search),
            label: const Text('Ir para a busca'),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / (1024 * 1024);
  return mb >= 1024
      ? '${(mb / 1024).toStringAsFixed(1)} GB'
      : '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}
