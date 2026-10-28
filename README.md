# GTVL

A clean, light home screen for Android TV, built to replace the Google TV
home screen. Codename GTVL; app ID `kanin.gtvl`.

Download the APK from [Releases](https://github.com/kanin-design/gtvl/releases).
`gtvl-<version>.apk` works on every TV; the `-arm64-v8a` and `-armeabi-v7a`
files are smaller builds for 64-bit and 32-bit Android.

- **Wallpaper:** Apple TV aerial films (streamed, crossfaded, the last one
  saved for an instant start); a picture, or a folder of them shown in turn,
  from the TV's storage; a wallpaper from this repository's `wallpapers`
  folder, downloaded when chosen; a video file; or a gradient.
- **Dock:** a full-width glass bar of favourite apps; Down shows all other apps.
  Apps show as wide TV banners or rounded squares, in three sizes, and the
  glass (blur, tint, edge lines) is adjustable.
- **Top bar:** hidden until Up; a second Up focuses it. Settings, network and
  VPN icons, each optional and reorderable, plus the clock.
- **Menus:** hold OK on an app for its menu; the settings panel slides in
  from the left, each level folding into a narrow column as the next opens,
  with the path on top.

## Build

Flutter 3.41.9 and JDK 17.

```bash
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Code

`lib/` holds one concern per file: `native.dart` (the Android bridge),
`config.dart` (settings as JSON), `apps.dart`, `status.dart`, `aerials.dart`,
`pictures.dart` (pictures from storage or the repository) and `player.dart`
(wallpaper video), then the UI: `home.dart`, `wallpaper.dart`, `tile.dart`,
`menu.dart`, `settings.dart` and the shared parts in `ui.dart`.
`android/app/src/main/kotlin/kanin/gtvl/MainActivity.kt` lists apps, renders
their tiles, launches them, and reports app, network and VPN changes.

## Config

Everything the user changes lives in `config.json` in the app's files folder,
written atomically with the previous version kept as `config.json.bak`. A video
wallpaper is set there for now, as `videoPath`.

## Credits

Aerial films by Apple. The film list comes from the
[Overflight](https://github.com/spocky/projectivy-plugin-wallpaper-overflight)
project (Apache-2.0). The typeface is [Inter](https://github.com/rsms/inter),
under the SIL Open Font License (`assets/fonts/OFL.txt`).
