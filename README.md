# Octans Player Runtime

Octans Player Runtime builds native playback artifacts for Octans clients. The current recipes produce LGPL-flavored `libmpv` runtimes and two Android Media3 artifacts. Corresponding source for those builds is this repository, including `scripts/patches/` and `build-manifests/`.

Source: <https://github.com/octans-media/open-octans-player-runtime>

This repository does not build the Octans server, the web UI, or the client applications.

## Artifacts

```text
octans-player-runtime-lgpl-win64
octans-player-runtime-lgpl-android-arm64
octans-player-runtime-lgpl-android-armeabi-v7a
octans-player-runtime-lgpl-media3-ffmpeg-decoder-android
octans-player-runtime-lgpl-media3-libass-renderer-android
```

The first three are `libmpv` runtimes. The Media3 FFmpeg decoder is one dual-ABI AAR for `arm64-v8a` and `armeabi-v7a`. The Media3 libass renderer is a pair of dual-ABI AARs built from `libass-android` `v0.5.0-beta01` plus `scripts/patches/libass-android/`.

`armeabi-v7a` targets Android 9 / API 28 with NEON. It is not a general 32-bit Android build.

The current stable libmpv release is `0.1.4` for win64, Android arm64, and `armeabi-v7a`. All three use mpv `v0.41.0-g413ff0b1` (`413ff0b1cd4585294803308a1a14be2fad30cede`), FFmpeg `9.0.2`, and libplacebo `92b5ac6db79f4d680eb656692f7bf51e9606f42a`. Android builds keep Vulkan and shaderc disabled. Media3 FFmpeg decoder `0.2.1` and libass renderer `0.1.1` are separate pins.

## Build

The supported host is Ubuntu 26.04 amd64, with Docker.

```bash
./scripts/build-win64-lgpl-runtime.sh
./scripts/verify-runtime-artifact.sh dist/octans-player-runtime-lgpl-win64

./scripts/build-android-arm64-lgpl-runtime.sh
./scripts/verify-android-runtime-artifact.sh dist/octans-player-runtime-lgpl-android-arm64

./scripts/build-android-armeabi-v7a-lgpl-runtime.sh
./scripts/verify-android-armeabi-v7a-runtime-artifact.sh dist/octans-player-runtime-lgpl-android-armeabi-v7a

./scripts/build-media3-ffmpeg-decoder-android.sh
./scripts/verify-media3-ffmpeg-decoder-artifact.sh dist/octans-player-runtime-lgpl-media3-ffmpeg-decoder-android

./scripts/build-media3-libass-renderer-android.sh
./scripts/verify-media3-libass-renderer-artifact.sh dist/octans-player-runtime-lgpl-media3-libass-renderer-android
```

Set `OCTANS_RUNTIME_VERSION` to stamp an artifact version. The default is `0.0.0-local`.

Build output stays under `dist/` and `.cache/`. Do not commit those directories, native binaries, or release archives.

## Publish

`scripts/publish-gitea-release-assets.sh` does not embed a registry address. Set these environment variables before uploading a release:

- `OCTANS_GITEA_URL`
- `OCTANS_GITEA_REPOSITORY_OWNER`
- `OCTANS_GITEA_REPOSITORY_NAME`
- `OCTANS_GITEA_RELEASE_TOKEN`

Gitea Actions reads the same addresses from repository variables, and reads the release token from a repository secret:

- `OCTANS_FFMPEG_RUNNER`
- `OCTANS_PLAYER_RUNTIME_CI_CACHE_ROOT`
- `OCTANS_GITEA_URL`
- `OCTANS_GITEA_HOST`
- `OCTANS_GITEA_REGISTRY_TOKEN`

## License

Licensing for this repository is scoped in `LICENSE`.

Octans-authored build scripts, Dockerfiles, workflows, manifests, and repository metadata are under the MIT License. The text is `LICENSES/MIT.txt`. `scripts/overlays/media3-ffmpeg-decoder/` stays under the Apache License, Version 2.0, as stated in its file headers. The text is `LICENSES/Apache-2.0.txt`.

Components downloaded at build time keep the licenses recorded in `build-manifests/`. This repository does not relicense them.

`libmpv` builds pass `-Dgpl=false`. FFmpeg builds do not pass `--enable-gpl` or `--enable-nonfree`, and they do not link `libx264`, `libx265`, or `libfdk-aac`.

Recorded component licenses include LGPL-2.1-or-later, LGPL-3.0-or-later, ISC, MIT, FTL, Zlib, BSD-2-Clause, WTFPL, Apache-2.0, libpng-2.0, and GPL-3.0-or-later WITH GCC-exception-3.1 for the MinGW GCC runtime. The libass renderer manifest records FreeType as `FreeType License or GPL-2.0-only`. The Media3 decoder module is Apache-2.0, and its FFmpeg `release/6.0` checkout is configured with GPL and nonfree disabled. The `libass-android` wrapper is MIT.

Built artifacts must keep their `licenses/` and `sources/` trees with the binaries.
