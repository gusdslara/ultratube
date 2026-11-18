# Verification, 2026-11-16

Device: Samsung Galaxy Watch 7, model SM-L300, 432 x 432 screenshot.

```
Gradle :wear:assembleDebug :wear:assembleDebugAndroidTest
BUILD SUCCESSFUL

adb install -r wear-debug.apk
Success

adb shell am instrument -w app.ultratube.wear.test/app.ultratube.wear.CatalogSmoke
PASS: 20 results; resolved audio and read 2048 media bytes

dart tool/check_ultratube_links.dart
PASS: 10 Shorts URL cases

dart analyze [changed application Dart files]
No issues found!

git diff --check
PASS
```

The network smoke test runs the actual NewPipeExtractor on the watch and does not
start audio. Audible playback and background endurance have not been tested.
`watch-launch.png` shows the installed application.

PPPlayer dependency resolution completed but plugin linking failed because Windows
symlink support is unavailable. No claim of a successful PPPlayer APK is made.
