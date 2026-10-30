# GTVL

A clean, light home screen for Android TV, built to replace the Google TV
home screen. Codename GTVL; app ID `kanin.gtvl`.

Download the APK from [Releases](https://github.com/kanin-design/gtvl/releases).
`gtvl-<version>.apk` works on every TV; the `-arm64-v8a` and `-armeabi-v7a`
files are smaller builds for 64-bit and 32-bit Android.

- **Wallpaper:** Apple TV aerial films (streamed, crossfaded, the last one
  saved for an instant start); videos or pictures, picked with previews from
  this repository's collection (downloaded when picked) or from the TV's
  storage, one or several, or whole folders, taking turns with a crossfade (a
  video loops seamlessly, for a set time when there are several); or a
  gradient. HDR films play on the TV's own video layer, in Dolby Vision where
  the TV shows it.
- **Dock:** a full-width glass bar of favourite apps; Down shows all other apps.
  Apps show as wide TV banners or square icons, in five sizes, with
  adjustable spacing, corners and height, and the glass (blur, tint, edge
  lines) is adjustable.
- **Rows of shows:** what you are watching and what is new, from Plex (signed
  in with a code at plex.tv/link) and from apps that share rows with the home
  screen, such as HBO Max and NRK TV, between the dock and all apps.
- **Top bar:** hidden until Up, which moves into it. Settings, network and
  VPN icons, each optional and reorderable, plus the clock.
- **Updates:** GTVL finds new versions in this repository's latest release,
  downloads the APK for the TV and checks it (size, SHA-256, that it is GTVL,
  newer, and signed with the same key) before Android installs it. With
  automatic updates on, it looks every few hours. From Android 12, once GTVL
  may install apps (the first update installed from Settings › About opens
  Android's switch for that), it then installs as the TV goes to standby; on
  older Android it waits under Settings › About, where an update can also be
  checked for and installed.
- **Buttons:** the remote's buttons (Netflix, ☰, Voice, media, volume, and
  Home and Back when held) can open an app, GTVL's settings or all apps, or do
  a system, media or volume action, separately for a press, a hold and a
  double press. Any other button is found by pressing it. It works everywhere
  once GTVL buttons is on in Android's accessibility settings (on the Shield:
  Device Preferences › Accessibility › Services); OK, the arrows and Power
  never change.
- **Menus:** hold OK on an app for its menu; the settings panel slides in
  from the left, each level folding into a narrow column as the next opens,
  with the path on top.

## Build

Flutter 3.41.9 and JDK 17.

```bash
flutter build apk --release --split-per-abi --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Split builds carry the version codes that updates use (2000 plus the build
number for 64-bit, 1000 plus it for 32-bit); a TV that has updated itself
refuses an all-in-one build of the same version as a downgrade.

Release builds are signed with the key that `android/key.properties` names
(kept out of git); without that file, with the debug key.

`tool/build.sh` builds the three release APKs into `dist/` (every TV, 32-bit
and 64-bit Android) and refuses to without the release key; `--upload` puts them
on the GitHub release for the version in `pubspec.yaml`, as a draft if it is new.
It also writes `gtvl-update.json`, which TVs read from the latest release to
update themselves, and `--notes FILE` adds release notes. To release: raise
the version and build number in `pubspec.yaml`, run
`tool/build.sh --upload --notes notes.md`, and publish the draft on GitHub;
TVs skip drafts and pre-releases.

## Code

`lib/` holds one concern per file: `native.dart` (the Android bridge),
`config.dart` (settings as JSON), `apps.dart`, `status.dart`, `aerials.dart`,
`media.dart` (pictures and videos from storage or the repository),
`player.dart` and `deck.dart` (wallpaper video, HDR beneath the screen),
`plex.dart` and `channels.dart` (rows of shows from Plex and from other
apps), `buttons.dart` (button names, actions and remaps) and `updates.dart`
(GTVL's own updates), then the UI: `home.dart`, `wallpaper.dart`,
`tile.dart`, `shows.dart`, `menu.dart`, `settings.dart` and the shared parts
in `ui.dart`.
`android/app/src/main/kotlin/kanin/gtvl/MainActivity.kt` lists apps, renders
their tiles, launches them, and reports app, network and VPN changes;
`AppRows.kt` reads the rows other apps share; `HdrDeck.kt` plays HDR films
on a video layer beneath the screen; `ButtonService.kt`, an accessibility
service, remaps the remote's buttons; `Updater.kt` checks a downloaded update
and hands it to Android's installer; `Launch.kt` starts apps.

## Config

Everything the user changes lives in `config.json` in the app's files folder,
written atomically with the previous version kept as `config.json.bak`, over
the defaults in `assets/defaults.json`.

## Collection

`wallpapers/` (pictures) and `videos/` hold the wallpapers GTVL offers to
download. Each file needs a 480 × 270 JPEG preview in the folder's `thumbs/`,
named like it (`videos/arc-fold.mp4` → `videos/thumbs/arc-fold.jpg`); the
gallery shows the file's name, so `arc-fold.mp4` reads "Arc fold".

## Credits

Aerial films by Apple. The film list comes from the
[Overflight](https://github.com/spocky/projectivy-plugin-wallpaper-overflight)
project (Apache-2.0). The typeface is [Inter](https://github.com/rsms/inter),
under the SIL Open Font License (`assets/fonts/OFL.txt`).
