import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playback/pip_handler.dart';
import '../../core/playback/playback_providers.dart'
    show playbackStatusProvider;

/// Picture-in-picture is wired on Android only (see MainActivity).
bool get pipSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Puts the playing video in a floating window right away, in its own shape
/// (vertical for Shorts). Leaving the app does the same on its own.
Future<void> enterVideoPip(WidgetRef ref) async {
  HapticFeedback.selectionClick();
  final ratio = ref.read(playbackStatusProvider).value?.videoAspectRatio;
  await PipHandler.enterPip(
    aspectRatio: ratio != null && ratio > 0 ? ratio : 16 / 9,
  );
}

/// Player control that opens picture-in-picture.
class PipButton extends ConsumerWidget {
  const PipButton({super.key, this.color = Colors.white});
  final Color color;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!pipSupported) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Janela flutuante',
      color: color,
      icon: const Icon(Icons.picture_in_picture_alt_outlined),
      onPressed: () => enterVideoPip(ref),
    );
  }
}
