# Ultratube fork

This fork is based on PPPlayer, commit
`6cea891ad31bb88a1d4ac1a0c524a57c795632e7`.
The original PPPlayer MIT copyright notice is preserved in `assets/LICENSE`.

The Android build additionally links NewPipeExtractor v0.27.1 through
`../android/media`. The combined Android/Wear distribution is provided under
GPL-3.0-or-later; see `COPYING` and `../android/NOTICE.md`. Retain corresponding
source, build files and dependency notices when distributing APKs.

Ultratube uses Flutter for its primary application. No Tauri runtime is used.
The fork removes Google Mobile Ads. Android catalog extraction and playback
use NewPipeExtractor and MediaKit; iOS uses a Dart port of the same catalog
over the YouTube web API (`lib/core/api/dart_catalog.dart`) plus MediaKit.
Other upstream platforms still use their
original playback paths and require separate validation.

LRCLIB supplies lyrics when a matching entry exists. Unavailable lyrics and
restricted videos are reported as unavailable rather than replaced with
invented content.
