import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local_library/local_library_service.dart';
import '../local_library/metadata_extractor.dart';
import '../models/track.dart';
import 'dart_downloads.dart';

enum DownloadState { queued, running, done, failed, canceled }

/// One offline download, mirrored from the native index (`Downloads.kt`).
class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.url,
    required this.title,
    required this.artist,
    required this.cover,
    required this.video,
    required this.state,
    required this.progress,
    this.file,
    this.coverFile,
    this.size,
    this.durationSeconds,
    this.resolution,
    this.error,
  });

  factory DownloadJob.fromJson(Map<String, dynamic> json) => DownloadJob(
    id: json['id'] as String,
    url: json['url'] as String? ?? '',
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    video: json['video'] as bool? ?? false,
    state: DownloadState.values.firstWhere(
      (s) => s.name == json['state'],
      orElse: () => DownloadState.failed,
    ),
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    file: json['file'] as String?,
    coverFile: json['coverFile'] as String?,
    size: (json['size'] as num?)?.toInt(),
    durationSeconds: (json['duration'] as num?)?.toInt(),
    resolution: json['resolution'] as String?,
    error: json['error'] as String?,
  );

  final String id;
  final String url;
  final String title;
  final String artist;
  final String cover;
  final bool video;
  final DownloadState state;
  final double progress;
  final String? file;
  final String? coverFile;
  final int? size;
  final int? durationSeconds;
  final String? resolution;
  final String? error;

  bool get active =>
      state == DownloadState.queued || state == DownloadState.running;

  String? get videoId {
    final uri = Uri.tryParse(url);
    return uri?.queryParameters['v'] ??
        (uri?.host == 'youtu.be' ? uri?.pathSegments.firstOrNull : null);
  }
}

/// Thin Dart client for the native download queue.
class UltratubeDownloads {
  const UltratubeDownloads();
  static const _channel = MethodChannel('app.ultratube/downloads');
  static const _events = EventChannel('app.ultratube/downloads/events');

  /// Android runs the native queue (`Downloads.kt`); iOS the Dart port.
  static bool get _native =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Stream<void> get changes => _native
      ? _events.receiveBroadcastStream().map((_) {})
      : DartDownloads.instance.changes;

  Future<String> enqueue(
    Track track, {
    required bool video,
    int maxHeight = 1080,
  }) async {
    final id = track.youtubeVideoId ?? track.spotifyId.split(':').last;
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id)) {
      throw ArgumentError('Este item não é um vídeo do YouTube');
    }
    final url = 'https://www.youtube.com/watch?v=$id';
    if (!_native) {
      return DartDownloads.instance.enqueue(
        url: url,
        title: track.name,
        artist: track.artistName,
        cover: track.albumImage ?? '',
        video: video,
        maxHeight: maxHeight,
      );
    }
    return (await _channel.invokeMethod<String>('enqueue', {
      'url': url,
      'title': track.name,
      'artist': track.artistName,
      'cover': track.albumImage ?? '',
      'video': video,
      'maxHeight': maxHeight,
    }))!;
  }

  Future<List<DownloadJob>> list() async {
    final List<dynamic> raw;
    if (_native) {
      final json = await _channel.invokeMethod<String>('list');
      raw = jsonDecode(json ?? '[]') as List;
    } else {
      raw = await DartDownloads.instance.list();
    }
    return raw
        .map((e) => DownloadJob.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> cancel(String id) => _native
      ? _channel.invokeMethod('cancel', {'id': id})
      : DartDownloads.instance.cancel(id);
  Future<void> retry(String id) => _native
      ? _channel.invokeMethod('retry', {'id': id})
      : DartDownloads.instance.retry(id);
  Future<void> remove(String id) => _native
      ? _channel.invokeMethod('remove', {'id': id})
      : DartDownloads.instance.remove(id);
}

/// Live list of downloads. Finished files are tagged and added to the local
/// library once, so they also show up in Library → Songs/Videos.
final downloadsProvider =
    StreamNotifierProvider<DownloadsNotifier, List<DownloadJob>>(
      DownloadsNotifier.new,
    );

class DownloadsNotifier extends StreamNotifier<List<DownloadJob>> {
  final _synced = <String>{};

  @override
  Stream<List<DownloadJob>> build() async* {
    if (!UltratubeDownloads.supported) {
      yield const [];
      return;
    }
    const api = UltratubeDownloads();
    var jobs = await api.list();
    unawaited(_sync(jobs));
    yield jobs;
    await for (final _ in api.changes) {
      jobs = await api.list();
      unawaited(_sync(jobs));
      yield jobs;
    }
  }

  Future<void> _sync(List<DownloadJob> jobs) async {
    final library = ref.read(localLibraryServiceProvider);
    for (final job in jobs) {
      final path = job.file;
      if (job.state != DownloadState.done || path == null) continue;
      if (!_synced.add(job.id)) continue;
      try {
        if (await library.isImported(path)) continue;
        await writeDownloadTags(
          path,
          title: job.title,
          artist: job.artist,
          coverPath: job.coverFile,
        );
        // Library views watch the database, so they refresh on their own.
        await library.importDownloadedFile(
          path,
          video: job.video,
          title: job.title,
          artist: job.artist,
          artworkPath: job.coverFile,
          durationMs: (job.durationSeconds ?? 0) * 1000,
        );
      } catch (error) {
        _synced.remove(job.id);
        debugPrint('Ultratube: falha ao adicionar download à biblioteca: $error');
      }
    }
  }

  /// Track for a finished job, ready to queue in the player.
  Future<Track?> trackFor(DownloadJob job) async {
    final path = job.file;
    if (job.state != DownloadState.done || path == null) return null;
    if (!await File(path).exists()) return null;
    final library = ref.read(localLibraryServiceProvider);
    return library.trackForDownloadedFile(
      path,
      title: job.title,
      artist: job.artist,
      artworkPath: job.coverFile,
      durationMs: (job.durationSeconds ?? 0) * 1000,
      video: job.video,
    );
  }
}

/// Convenience for buttons: queue a download and tell the user.
Future<void> startDownload(
  Track track, {
  required bool video,
  int maxHeight = 1080,
}) async {
  try {
    await const UltratubeDownloads().enqueue(
      track,
      video: video,
      maxHeight: maxHeight,
    );
    LocalLibraryService.showNotice(
      video ? 'Baixando vídeo: ${track.name}' : 'Baixando áudio: ${track.name}',
    );
  } catch (error) {
    LocalLibraryService.showNotice('Não foi possível baixar: $error');
  }
}
