import 'package:flutter/foundation.dart';

/// Ultratube (YouTube feed, own player, Twitch, downloads) runs on phones and
/// on desktop (Windows, macOS, Linux). Android talks to NewPipe natively;
/// iOS and desktop use the Dart port of the same catalog.
bool get isUltratubePlatform => !kIsWeb && (isUltratubeMobile || isUltratubeDesktop);

/// Phones/tablets: orientation-driven fullscreen, haptics, downloads.
bool get isUltratubeMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Desktop windows: mouse/keyboard, window fullscreen, side navigation.
bool get isUltratubeDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);
