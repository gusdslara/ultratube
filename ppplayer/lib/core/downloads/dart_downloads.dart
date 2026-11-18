import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yte;

import '../api/dart_catalog.dart';
import '../api/innertube.dart' show artistName;

/// Dart port of the Android `Downloads.kt` queue for iOS: one job at a time,
/// index persisted as JSON, files in the app's Documents/downloads folder.
///
/// Video above 360p comes as separate MP4 video + M4A audio; they are joined
/// without re-encoding by AVFoundation (`app.ultratube/ios_media`).
/// iOS suspends apps in the background, so a running job pauses there and
/// resumes when the app returns (its state is restored as queued).
class DartDownloads {
  DartDownloads._();
  static final instance = DartDownloads._();

  static const queued = 'queued';
  static const running = 'running';
  static const done = 'done';
  static const failed = 'failed';
  static const canceled = 'canceled';

  static const _media = MethodChannel('app.ultratube/ios_media');
  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

  final _jobs = <String, Map<String, dynamic>>{};
  final _changes = StreamController<void>.broadcast();
  final _http = http.Client();
  Future<void>? _loading;
  Directory? _dir;
  bool _working = false;
  String? _currentId;
  bool _cancelCurrent = false;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  Stream<void> get changes => _changes.stream;

  Future<Directory> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    final docs = await getApplicationDocumentsDirectory();
    return _dir = await Directory('${docs.path}/downloads').create(recursive: true);
  }

  File _index(Directory dir) => File('${dir.path}/index.json');

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final dir = await _directory();
    try {
      final list = jsonDecode(await _index(dir).readAsString()) as List;
      for (final raw in list) {
        final job = Map<String, dynamic>.from(raw as Map);
        // An interrupted job resumes from the queue.
        if (job['state'] == running) {
          job['state'] = queued;
          job['progress'] = 0.0;
        }
        // The app container path changes on updates: keep only the name.
        for (final key in ['file', 'coverFile']) {
          final path = job[key] as String?;
          if (path != null && path.isNotEmpty) {
            job[key] = '${dir.path}/${path.split('/').last}';
          }
        }
        _jobs[job['id'] as String] = job;
      }
    } catch (_) {
      // No index yet (or unreadable): start empty.
    }
    if (_jobs.values.any((j) => j['state'] == queued)) unawaited(_pump());
  }

  Future<void> _persist() async {
    final dir = await _directory();
    final tmp = File('${dir.path}/index.json.tmp');
    await tmp.writeAsString(jsonEncode(_jobs.values.toList()));
    await tmp.rename(_index(dir).path);
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ------------------------------------------------------------- queue

  Future<String> enqueue({
    required String url,
    required String title,
    required String artist,
    required String cover,
    required bool video,
    required int maxHeight,
  }) async {
    await _ensureLoaded();
    for (final job in _jobs.values) {
      if (job['url'] == url &&
          job['video'] == video &&
          {queued, running, done}.contains(job['state'])) {
        return job['id'] as String;
      }
    }
    final id = const Uuid().v4();
    _jobs[id] = {
      'id': id,
      'url': url,
      'title': title,
      'artist': artist,
      'cover': cover,
      'video': video,
      'maxHeight': maxHeight,
      'state': queued,
      'progress': 0.0,
      'created': DateTime.now().millisecondsSinceEpoch,
    };
    await _persist();
    _changed();
    unawaited(_pump());
    return id;
  }

  Future<List<Map<String, dynamic>>> list() async {
    await _ensureLoaded();
    final jobs = _jobs.values.map((j) => Map<String, dynamic>.from(j)).toList()
      ..sort((a, b) => (b['created'] as int? ?? 0).compareTo(a['created'] as int? ?? 0));
    return jobs;
  }

  Future<void> cancel(String id) async {
    await _ensureLoaded();
    if (_currentId == id) _cancelCurrent = true;
    final job = _jobs[id];
    if (job != null && job['state'] == queued) job['state'] = canceled;
    await _persist();
    _changed();
  }

  Future<void> retry(String id) async {
    await _ensureLoaded();
    final job = _jobs[id];
    if (job != null && {failed, canceled}.contains(job['state'])) {
      job
        ..['state'] = queued
        ..['progress'] = 0.0
        ..remove('error');
    }
    await _persist();
    _changed();
    unawaited(_pump());
  }

  Future<void> remove(String id) async {
    await _ensureLoaded();
    if (_currentId == id) _cancelCurrent = true;
    final job = _jobs.remove(id);
    if (job != null) {
      for (final key in ['file', 'coverFile']) {
        final path = job[key] as String?;
        if (path != null && path.isNotEmpty) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
      }
    }
    await _persist();
    _changed();
  }

  Future<void> _pump() async {
    if (_working) return;
    _working = true;
    try {
      while (true) {
        final next = _jobs.values.where((j) => j['state'] == queued).firstOrNull;
        if (next == null) break;
        next['state'] = running;
        await _persist();
        _changed();
        await _run(next);
      }
    } finally {
      _working = false;
    }
  }

  // --------------------------------------------------------------- job

  Future<void> _run(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    _currentId = id;
    _cancelCurrent = false;
    final temps = <File>[];
    try {
      final catalog = DartCatalog.instance;
      final videoId = Uri.parse(job['url'] as String).queryParameters['v'] ?? '';
      final meta = await catalog.metadata(videoId);
      final manifest = await catalog.manifestFor(videoId);
      final dir = await _directory();
      final artist = artistName(meta.author);
      var base = _safeName('$artist - ${meta.title}');
      if (base.isEmpty) base = id;

      final coverFile = File('${dir.path}/$id.jpg');
      try {
        await _fetch(meta.thumbnails.maxResUrl, coverFile, (_, _) {});
      } catch (_) {
        try {
          await _fetch(meta.thumbnails.highResUrl, coverFile, (_, _) {});
        } catch (_) {}
      }

      final audio = DartCatalog.bestAudio(manifest);
      if (audio == null) throw StateError('Áudio indisponível para este conteúdo');
      final File output;
      if (job['video'] == true) {
        final maxHeight = ((job['maxHeight'] as num?)?.toInt() ?? 1080).clamp(144, 4320);
        // AVFoundation joins MP4 video with M4A audio only.
        final videoOnly = DartCatalog.bestVideoOnly(manifest, maxHeight, mp4Only: true);
        output = await _uniqueFile(dir, base, 'mp4');
        temps.add(output);
        int? height;
        if (videoOnly != null && audio.container == yte.StreamContainer.mp4) {
          final v = File('${dir.path}/$id.video.mp4');
          final a = File('${dir.path}/$id.audio.m4a');
          temps.addAll([v, a]);
          final total = videoOnly.size.totalBytes + audio.size.totalBytes;
          var videoBytes = 0;
          await _fetch(videoOnly.url.toString(), v, (got, size) {
            videoBytes = got;
            _progress(id, got, total > 0 ? total : size * 2);
          });
          await _fetch(audio.url.toString(), a, (got, _) {
            _progress(id, videoBytes + got, total > 0 ? total : videoBytes * 2);
          });
          await _media.invokeMethod<void>('mux', {
            'video': v.path,
            'audio': a.path,
            'output': output.path,
          });
          height = videoOnly.videoResolution.height;
        } else {
          final muxed = manifest.muxed
              .where((s) => s.container == yte.StreamContainer.mp4)
              .toList()
            ..sort((x, y) => x.videoResolution.height.compareTo(y.videoResolution.height));
          if (muxed.isEmpty) throw StateError('Vídeo indisponível para download');
          await _fetch(muxed.last.url.toString(), output, (got, size) => _progress(id, got, size));
          height = muxed.last.videoResolution.height;
        }
        temps.remove(output);
        job['resolution'] = '${height}p';
      } else {
        final ext = audio.container == yte.StreamContainer.mp4 ? 'm4a' : audio.container.name;
        output = await _uniqueFile(dir, base, ext);
        temps.add(output);
        await _fetch(audio.url.toString(), output, (got, size) => _progress(id, got, size));
        temps.remove(output);
      }
      job
        ..['state'] = done
        ..['progress'] = 1.0
        ..['file'] = output.path
        ..['size'] = await output.length()
        ..['title'] = meta.title
        ..['artist'] = artist
        ..['duration'] = meta.duration?.inSeconds ?? 0
        ..['finished'] = DateTime.now().millisecondsSinceEpoch;
      if (await coverFile.exists()) job['coverFile'] = coverFile.path;
    } catch (error) {
      final wasCanceled = _cancelCurrent;
      job['state'] = wasCanceled ? canceled : failed;
      if (!wasCanceled) {
        job['error'] = '$error';
        debugPrint('Ultratube: download $id falhou: $error');
      }
    } finally {
      for (final file in temps) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      _currentId = null;
      if (_jobs.containsKey(id)) await _persist();
      _changed();
    }
  }

  void _progress(String id, int done, int total) {
    final job = _jobs[id];
    if (job == null || total <= 0) return;
    job['progress'] = (done / total).clamp(0.0, 0.99);
    final now = DateTime.now();
    // Throttled like the native queue (~2 updates per second).
    if (now.difference(_lastProgress) > const Duration(milliseconds: 500)) {
      _lastProgress = now;
      _changed();
    }
  }

  static String _safeName(String value) {
    final clean = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return clean.length > 120 ? clean.substring(0, 120) : clean;
  }

  static Future<File> _uniqueFile(Directory dir, String base, String ext) async {
    var file = File('${dir.path}/$base.$ext');
    var n = 2;
    while (await file.exists()) {
      file = File('${dir.path}/$base ($n).$ext');
      n++;
    }
    return file;
  }

  /// Downloads in ~10 MB ranges: YouTube throttles single long requests.
  Future<void> _fetch(
    String url,
    File target,
    void Function(int done, int total) progress,
  ) async {
    const chunk = 10 * 1024 * 1024;
    var offset = 0;
    var total = -1;
    final sink = target.openWrite();
    try {
      while (total < 0 || offset < total) {
        if (_cancelCurrent) throw StateError('Cancelado');
        final end = total > 0 ? (offset + chunk < total ? offset + chunk : total) - 1 : offset + chunk - 1;
        final request = http.Request('GET', Uri.parse(url))
          ..headers['Range'] = 'bytes=$offset-$end'
          ..headers['User-Agent'] = _ua;
        final response = await _http.send(request).timeout(const Duration(seconds: 60));
        if (response.statusCode == 416 && total < 0) {
          await response.stream.drain<void>();
          total = offset;
          break;
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.stream.drain<void>();
          throw HttpException('Falha no download (HTTP ${response.statusCode})');
        }
        if (response.statusCode == 200) {
          // Server ignored the range: the whole body comes once.
          total = response.contentLength ?? -1;
        } else if (total < 0) {
          final range = response.headers['content-range'] ?? '';
          total = int.tryParse(range.split('/').last) ?? -1;
        }
        var received = 0;
        await for (final data in response.stream) {
          if (_cancelCurrent) throw StateError('Cancelado');
          sink.add(data);
          offset += data.length;
          received += data.length;
          progress(offset, total);
        }
        if (response.statusCode == 200 || total < 0 || received == 0) {
          total = offset;
        }
      }
    } finally {
      await sink.close();
    }
  }
}
