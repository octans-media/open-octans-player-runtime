/*
 * Copyright (C) 2026 Octans
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package androidx.media3.decoder.ffmpeg;

import androidx.media3.common.util.UnstableApi;

/** Octans FFmpeg audio processing options for the Media3 FFmpeg decoder. */
@UnstableApi
public final class FfmpegAudioProcessingOptions {

  /* package */ static final int MODE_OFF = 0;
  /* package */ static final int MODE_LOCAL_DIALOGUE_STEREO = 1;

  private static final FfmpegAudioProcessingOptions OFF =
      new FfmpegAudioProcessingOptions(MODE_OFF);
  private static final FfmpegAudioProcessingOptions LOCAL_DIALOGUE_STEREO =
      new FfmpegAudioProcessingOptions(MODE_LOCAL_DIALOGUE_STEREO);

  private final int mode;

  private FfmpegAudioProcessingOptions(int mode) {
    this.mode = mode;
  }

  /** Returns options that keep upstream FFmpeg decoder behavior unchanged. */
  public static FfmpegAudioProcessingOptions off() {
    return OFF;
  }

  /** Returns options that apply Octans local dialogue enhanced stereo processing. */
  public static FfmpegAudioProcessingOptions localDialogueStereo() {
    return LOCAL_DIALOGUE_STEREO;
  }

  /* package */ int getMode() {
    return mode;
  }

  /** Returns whether Octans local dialogue stereo processing is enabled. */
  public boolean isLocalDialogueStereoEnabled() {
    return mode != MODE_OFF;
  }
}
