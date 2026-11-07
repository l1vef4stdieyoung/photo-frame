# photo-frame

A photo frame / clock / weather / now-playing screen for a wall tablet.

- **Web frame:** `docs/index.html`, hosted with GitHub Pages at https://l1vef4stdieyoung.github.io/photo-frame/.
  Changing it updates every device on its next reload (the app also reloads every night at 4:00).
- **Android app:** a Capacitor shell (`android/`) that loads the hosted frame and adds real screen brightness,
  start on boot, full screen, keep-awake, an in-app Spotify login and network access without browser restrictions.
- **Builds:** every change to `android/`, `www/` or the Capacitor config builds a signed APK on GitHub Actions and publishes it as
  `photo-frame.apk` on the latest release.

## Releasing a new app version
1. Raise `versionName` in `android/app/build.gradle`.
2. Set the same value as `"apk"` in `docs/version.json`.
3. Push. The tablet shows "App update available" and downloads the APK from the latest release.
