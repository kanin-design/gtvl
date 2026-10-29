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
  gradient.
- **Dock:** a full-width glass bar of favourite apps; Down shows all other apps.
  Apps show as wide TV banners or rounded squares, in three sizes, and the
  glass (blur, tint, edge lines) is adjustable.
- **Top bar:** hidden until Up; a second Up focuses it. Settings, network and
  VPN icons, each optional and reorderable, plus the clock.
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
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Release builds are signed with the key that `android/key.properties` names
(kept out of git); without that file, with the debug key.

`tool/build.sh` builds the three release APKs into `dist/` (every TV, 32-bit
and 64-bit Android) and refuses to without the release key; `--upload` puts them
on the GitHub release for the version in `pubspec.yaml`, as a draft if it is new.

## Code

`lib/` holds one concern per file: `native.dart` (the Android bridge),
`config.dart` (settings as JSON), `apps.dart`, `status.dart`, `aerials.dart`,
`media.dart` (pictures and videos from storage or the repository),
`player.dart` (wallpaper video) and `buttons.dart` (button names, actions and
remaps), then the UI: `home.dart`, `wallpaper.dart`, `tile.dart`,
`menu.dart`, `settings.dart` and the shared parts in `ui.dart`.
`android/app/src/main/kotlin/kanin/gtvl/MainActivity.kt` lists apps, renders
their tiles, launches them, and reports app, network and VPN changes;
`ButtonService.kt`, an accessibility service, remaps the remote's buttons.

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
