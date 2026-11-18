import 'package:flutter/foundation.dart';

/// Phones run Ultratube (YouTube feed, own player, downloads); desktop keeps
/// the PPPlayer screens. Android talks to NewPipe natively, iOS uses the
/// Dart port of the same catalog.
bool get isUltratubePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);
