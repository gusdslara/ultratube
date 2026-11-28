# Third-party notices

Ultratube is built on top of other people's open-source work. This file lists the
projects that are bundled into the released binaries, with their licenses. The
complete license texts ship inside each package (Flutter's `LicenseRegistry`, shown in
the app under *About › Licenses*, and the Gradle/pub caches when building from source).

## Upstream project

| Project | Used for | License |
|---|---|---|
| [PPPlayer](https://github.com/ppplayer-labs/app) (commit `6cea891`) | Base of the Flutter phone/desktop/iOS app (`ppplayer/`) | MIT — notice kept in `ppplayer/assets/LICENSE`; fork notes in `ppplayer/ULTRATUBE-NOTICE.md` |

## Android / Wear OS (`android/`, `ppplayer/android/`)

| Library | Used for | License |
|---|---|---|
| [NewPipeExtractor](https://github.com/TeamNewPipe/NewPipeExtractor) v0.27.1 | YouTube search, channels, playlists and stream extraction | GPL-3.0 |
| [AndroidX Media3 / ExoPlayer](https://github.com/androidx/media) | Playback on the watch, media session | Apache-2.0 |
| [OkHttp](https://github.com/square/okhttp) | HTTP client | Apache-2.0 |
| [Kotlin, kotlinx.coroutines](https://github.com/Kotlin/kotlinx.coroutines) | Language runtime | Apache-2.0 |
| AndroidX (core, activity, viewpager2, wear-ongoing) | Android UI and Wear OS integration | Apache-2.0 |
| [ZXing](https://github.com/zxing/zxing) | QR code for "Sign in with phone" | Apache-2.0 |
| [org.json](https://github.com/stleary/JSON-java) | JSON parsing | Public domain |

Because NewPipeExtractor is GPL-3.0, the combined Android/Wear distribution is
**GPL-3.0-or-later** (see `android/LICENSE` and `android/NOTICE.md`).

## Flutter app (`ppplayer/`)

| Library | Used for | License |
|---|---|---|
| [Flutter](https://github.com/flutter/flutter) and Dart SDK | UI framework | BSD-3-Clause |
| [media_kit](https://github.com/media-kit/media-kit) (`media_kit`, `media_kit_video`, `media_kit_libs_*`) | Video/audio player | MIT |
| [libmpv](https://github.com/mpv-player/mpv) (bundled by `media_kit_libs_*` / `flutter_media_kit`) | Playback engine | LGPL-2.1-or-later (as built by media_kit) |
| [FFmpeg](https://ffmpeg.org) (bundled with libmpv) | Demuxing/decoding | LGPL-2.1-or-later (as built by media_kit) |
| [audio_service](https://github.com/ryanheise/audio_service), [audio_session](https://github.com/ryanheise/audio_session) | Background playback, media notification | MIT |
| [Riverpod](https://github.com/rrousselGit/riverpod) | State management | MIT |
| [go_router](https://pub.dev/packages/go_router) | Navigation | BSD-3-Clause |
| [drift](https://github.com/simolus3/drift), [sqlite3](https://www.sqlite.org) | Local database | MIT / public domain |
| [hive_ce](https://github.com/IO-Design-Team/hive_ce) | Key-value storage | Apache-2.0 |
| [dio](https://github.com/cfug/dio), [http](https://pub.dev/packages/http) | HTTP clients | MIT / BSD-3-Clause |
| [youtube_explode_dart](https://github.com/Hexer10/youtube_explode_dart) | YouTube metadata on non-Android platforms | BSD-3-Clause |
| [youtube_player_iframe](https://github.com/sarbagyastha/youtube_player_flutter) (patched copy in `lib/core/playback/packages/`) | Legacy upstream player path | BSD-3-Clause |
| [metadata_god](https://github.com/KRTirtho/metadata_god) (vendored) with [lofty](https://github.com/Serial-ATA/lofty-rs) and [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) | Audio file tags for downloads | MIT / MIT OR Apache-2.0 |
| [cached_network_image](https://github.com/Baseflow/flutter_cached_network_image), flutter_cache_manager | Image cache | MIT |
| [flutter_secure_storage](https://github.com/juliansteenbakker/flutter_secure_storage) | Encrypted storage for account cookies and API keys | BSD-3-Clause |
| [flutter_animate](https://github.com/gskinner/flutter_animate) | Animations | BSD-3-Clause |
| [font_awesome_flutter](https://github.com/fluttercommunity/font_awesome_flutter) | Icons | MIT (code), CC BY 4.0 / SIL OFL 1.1 (icons/fonts) |
| flutter_chromium_webview, webview_win_floating, connectivity_plus, path_provider, permission_handler, url_launcher, package_info_plus, file_picker, image_picker, uuid, crypto, xml, intl, freezed/json annotations, windows_taskbar, fullscreen_window, macos_file_open_handler, dart_cast | Platform plumbing | BSD-3-Clause / MIT / Apache-2.0 (see each package) |

## Online services (no code bundled)

| Service | Used for | Terms |
|---|---|---|
| [SponsorBlock](https://sponsor.ajay.app) | Skipping sponsor segments | Database: CC BY-NC-SA 4.0 |
| [LRCLIB](https://lrclib.net) | Lyrics | Free public API |
| [7TV](https://7tv.app), [BetterTTV](https://betterttv.com) | Twitch chat emotes | Their public APIs |
| [Google AI Studio / Gemini](https://ai.google.dev) | Optional "Ask" feature, with the user's own API key | Google's terms |

## Trademarks

YouTube, YouTube Music, Google, Gemini, Android, Wear OS and Galaxy Watch are trademarks of
their respective owners (Google LLC, Samsung). Twitch is a trademark of Twitch Interactive, Inc.
Ultratube is an independent project and is **not affiliated with, endorsed or sponsored by**
any of them.
