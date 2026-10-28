# GTVL

A clean, light home screen for Android TV, built to replace the Google TV
home screen. Codename GTVL; app ID `kanin.gtvl`.

- **Wallpaper:** Apple TV aerial films (streamed, crossfaded, the last one
  saved for an instant start), a video or picture file, or a gradient.
- **Dock:** a full-width glass bar of favourite apps; Down shows all other apps.
- **Top bar:** hidden until Up; a second Up focuses it. Settings, network and
  VPN icons, each optional and reorderable, plus the clock.
- **Menus:** hold OK on an app for its menu; the settings panel slides in
  from the left.

## Build

Flutter 3.41.9 and JDK 17.

```bash
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Code

`lib/` holds one concern per file: `native.dart` (the Android bridge),
`config.dart` (settings as JSON), `apps.dart`, `status.dart`, `aerials.dart`
and `player.dart` (wallpaper video), then the UI: `home.dart`, `tile.dart`,
`menu.dart`, `settings.dart` and the shared parts in `ui.dart`.
`android/app/src/main/kotlin/kanin/gtvl/MainActivity.kt` lists apps, renders
their tiles, launches them, and reports app, network and VPN changes.

## Config

Everything the user changes lives in `config.json` in the app's files folder,
written atomically with the previous version kept as `config.json.bak`. A video
or picture wallpaper is set there for now, as `videoPath` or `imagePath`.

## Credits

Aerial films by Apple. The film list comes from the
[Overflight](https://github.com/spocky/projectivy-plugin-wallpaper-overflight)
project (Apache-2.0).
