# Octans Player Runtime

This repository builds native playback artifacts for Octans clients. `libmpv` builds pass `-Dgpl=false`. FFmpeg builds do not pass `--enable-gpl` or `--enable-nonfree`, and they do not link `libx264`, `libx265`, or `libfdk-aac`.

## Layout

- `scripts/build-win64-lgpl-runtime.sh` builds the Windows x64 `libmpv` runtime.
- `scripts/build-android-arm64-lgpl-runtime.sh` builds the Android arm64 `libmpv` runtime.
- `scripts/build-android-armeabi-v7a-lgpl-runtime.sh` builds the Android `armeabi-v7a` `libmpv` runtime.
- `scripts/build-media3-ffmpeg-decoder-android.sh` builds the Media3 FFmpeg decoder AAR.
- `scripts/build-media3-libass-renderer-android.sh` builds the Media3 libass renderer AARs.
- `scripts/patches/libass-android/` is applied to the `libass-android` source.
- `build-manifests/` records component versions, source URLs, and licenses.
- `.gitea/workflows/` builds and publishes from repository variables and secrets. Do not write registry hosts or credentials into the workflow files.

## Build

```bash
./scripts/build-win64-lgpl-runtime.sh
./scripts/verify-runtime-artifact.sh dist/octans-player-runtime-lgpl-win64
```

The other artifact entry points are listed in `README.md`. Build output stays under `dist/` and `.cache/` unless `OCTANS_RUNTIME_OUTPUT` or `OCTANS_RUNTIME_SOURCE_CACHE` is set. Do not commit `dist/`, `.cache/`, packages, or native binaries.

`scripts/publish-gitea-release-assets.sh` requires `OCTANS_GITEA_URL`, `OCTANS_GITEA_REPOSITORY_OWNER`, and `OCTANS_GITEA_REPOSITORY_NAME`. It has no default registry address.
