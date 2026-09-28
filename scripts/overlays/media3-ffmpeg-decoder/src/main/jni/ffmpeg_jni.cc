/*
 * Copyright (C) 2016 The Android Open Source Project
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
#include <android/log.h>
#include <jni.h>
#include <stdlib.h>
#include <string.h>

extern "C" {
#ifdef __cplusplus
#define __STDC_CONSTANT_MACROS
#ifdef _STDINT_H
#undef _STDINT_H
#endif
#include <stdint.h>
#endif
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
}

#define LOG_TAG "ffmpeg_jni"
#define LOGE(...) \
  ((void)__android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__))
#define LOGI(...) \
  ((void)__android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__))
#define LOGD(...) \
  ((void)__android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__))

#define LIBRARY_FUNC(RETURN_TYPE, NAME, ...)                               \
  extern "C" {                                                             \
  JNIEXPORT RETURN_TYPE                                                    \
  Java_androidx_media3_decoder_ffmpeg_FfmpegLibrary_##NAME(JNIEnv* env,    \
                                                           jobject thiz,   \
                                                           ##__VA_ARGS__); \
  }                                                                        \
  JNIEXPORT RETURN_TYPE                                                    \
  Java_androidx_media3_decoder_ffmpeg_FfmpegLibrary_##NAME(                \
      JNIEnv* env, jobject thiz, ##__VA_ARGS__)

#define AUDIO_DECODER_FUNC(RETURN_TYPE, NAME, ...)               \
  extern "C" {                                                   \
  JNIEXPORT RETURN_TYPE                                          \
  Java_androidx_media3_decoder_ffmpeg_FfmpegAudioDecoder_##NAME( \
      JNIEnv* env, jobject thiz, ##__VA_ARGS__);                 \
  }                                                              \
  JNIEXPORT RETURN_TYPE                                          \
  Java_androidx_media3_decoder_ffmpeg_FfmpegAudioDecoder_##NAME( \
      JNIEnv* env, jobject thiz, ##__VA_ARGS__)

#define ERROR_STRING_BUFFER_LENGTH 256
#define CHANNEL_LAYOUT_BUFFER_LENGTH 256
#define FILTER_ARGS_BUFFER_LENGTH 768

// Output format corresponding to AudioFormat.ENCODING_PCM_16BIT.
static const AVSampleFormat OUTPUT_FORMAT_PCM_16BIT = AV_SAMPLE_FMT_S16;
// Output format corresponding to AudioFormat.ENCODING_PCM_FLOAT.
static const AVSampleFormat OUTPUT_FORMAT_PCM_FLOAT = AV_SAMPLE_FMT_FLT;

static const int AUDIO_PROCESSING_MODE_OFF = 0;
static const int AUDIO_PROCESSING_MODE_LOCAL_DIALOGUE_STEREO = 1;

static const char* OCTANS_ENABLED_FILTERS =
    "abuffer,abuffersink,aformat,pan,dynaudnorm,aresample";

static const char* OCTANS_LOCAL_DIALOGUE_STEREO_GRAPH =
    "aformat=sample_fmts=fltp,"
    "pan=stereo|"
    "FL=1.00*FL+1.05*FC+0.35*SL+0.35*BL+0.25*BC+0.15*TFL+0.10*TBL+"
    "0.05*LFE|"
    "FR=1.00*FR+1.05*FC+0.35*SR+0.35*BR+0.25*BC+0.15*TFR+0.10*TBR+"
    "0.05*LFE,"
    "dynaudnorm=framelen=100:gausssize=3:maxgain=10,"
    "aresample=48000";

// LINT.IfChange
static const int AUDIO_DECODER_ERROR_INVALID_DATA = -1;
static const int AUDIO_DECODER_ERROR_OTHER = -2;
// LINT.ThenChange(../java/androidx/media3/decoder/ffmpeg/FfmpegAudioDecoder.java)

static jmethodID growOutputBufferMethod;

struct GrowOutputBufferCallback {
  uint8_t* operator()(int requiredSize) const;

  JNIEnv* env;
  jobject thiz;
  jobject decoderOutputBuffer;
};

struct OctansFfmpegAudioDecoderContext {
  AVCodecContext* codecContext;
  SwrContext* resampleContext;
  AVFilterGraph* filterGraph;
  AVFilterContext* bufferSourceContext;
  AVFilterContext* bufferSinkContext;
  AVSampleFormat outputSampleFormat;
  AVChannelLayout outputChannelLayout;
  AVChannelLayout resampleInputChannelLayout;
  AVChannelLayout resampleOutputChannelLayout;
  AVSampleFormat resampleInputSampleFormat;
  AVSampleFormat resampleOutputSampleFormat;
  int resampleInputSampleRate;
  int resampleOutputSampleRate;
  AVChannelLayout filterInputChannelLayout;
  AVSampleFormat filterInputSampleFormat;
  int filterInputSampleRate;
  int outputSampleRate;
  int audioProcessingMode;
  bool resampleConfigured;
  bool filterConfigured;
};

/**
 * Returns the AVCodec with the specified name, or NULL if it is not available.
 */
const AVCodec* getCodecByName(JNIEnv* env, jstring codecName);

/**
 * Allocates and opens a new AVCodecContext for the specified codec, passing the
 * provided extraData as initialization data for the decoder if it is non-NULL.
 * Returns the created context.
 */
AVCodecContext* createCodecContext(JNIEnv* env, const AVCodec* codec,
                                   jbyteArray extraData, jboolean outputFloat,
                                   jint rawSampleRate, jint rawChannelCount);

OctansFfmpegAudioDecoderContext* createDecoderContext(
    JNIEnv* env, const AVCodec* codec, jbyteArray extraData,
    jboolean outputFloat, jint rawSampleRate, jint rawChannelCount,
    jint audioProcessingMode);

/**
 * Decodes the packet into the output buffer, returning the number of bytes
 * written, or a negative AUDIO_DECODER_ERROR constant value in the case of an
 * error.
 */
int decodePacket(OctansFfmpegAudioDecoderContext* decoderContext,
                 AVPacket* packet, uint8_t* outputBuffer, int outputSize,
                 GrowOutputBufferCallback growBuffer);

int appendFrameToOutput(OctansFfmpegAudioDecoderContext* decoderContext,
                        AVFrame* frame, uint8_t** outputBuffer,
                        int* outputSize, int* outSize,
                        GrowOutputBufferCallback growBuffer);

int processFilteredFrame(OctansFfmpegAudioDecoderContext* decoderContext,
                         AVFrame* frame, uint8_t** outputBuffer,
                         int* outputSize, int* outSize,
                         GrowOutputBufferCallback growBuffer);

int ensureFilterGraph(OctansFfmpegAudioDecoderContext* decoderContext,
                      AVFrame* frame);

bool isLocalDialogueStereoMode(int audioProcessingMode);

int ensureResampleContext(OctansFfmpegAudioDecoderContext* decoderContext,
                          const AVChannelLayout* inputChannelLayout,
                          AVSampleFormat inputSampleFormat,
                          int inputSampleRate,
                          const AVChannelLayout* outputChannelLayout,
                          AVSampleFormat outputSampleFormat,
                          int outputSampleRate);

bool copyFrameChannelLayout(AVFrame* frame, AVCodecContext* codecContext,
                            AVChannelLayout* out);

void setDecoderOutputFormat(OctansFfmpegAudioDecoderContext* decoderContext,
                            const AVChannelLayout* channelLayout,
                            int sampleRate);

/**
 * Transforms ffmpeg AVERROR into a negative AUDIO_DECODER_ERROR constant value.
 */
int transformError(int errorNumber);

/**
 * Outputs a log message describing the avcodec error number.
 */
void logError(const char* functionName, int errorNumber);

void logChannelLayout(const char* label, const AVChannelLayout* channelLayout);

/**
 * Releases allocated state.
 */
void releaseFilterGraph(OctansFfmpegAudioDecoderContext* decoderContext);
void releaseResampleContext(OctansFfmpegAudioDecoderContext* decoderContext);
void releaseCodecContext(AVCodecContext* context);
void releaseDecoderContext(OctansFfmpegAudioDecoderContext* decoderContext);

jint JNI_OnLoad(JavaVM* vm, void* reserved) {
  JNIEnv* env;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    LOGE("JNI_OnLoad: GetEnv failed");
    return -1;
  }
  jclass clazz =
      env->FindClass("androidx/media3/decoder/ffmpeg/FfmpegAudioDecoder");
  if (!clazz) {
    LOGE("JNI_OnLoad: FindClass failed");
    return -1;
  }
  growOutputBufferMethod =
      env->GetMethodID(clazz, "growOutputBuffer",
                       "(Landroidx/media3/decoder/"
                       "SimpleDecoderOutputBuffer;I)Ljava/nio/ByteBuffer;");
  if (!growOutputBufferMethod) {
    LOGE("JNI_OnLoad: GetMethodID failed");
    return -1;
  }
  return JNI_VERSION_1_6;
}

LIBRARY_FUNC(jstring, ffmpegGetVersion) {
  return env->NewStringUTF(LIBAVCODEC_IDENT);
}

LIBRARY_FUNC(jint, ffmpegGetInputBufferPaddingSize) {
  return (jint)AV_INPUT_BUFFER_PADDING_SIZE;
}

LIBRARY_FUNC(jboolean, ffmpegHasDecoder, jstring codecName) {
  return getCodecByName(env, codecName) != NULL;
}

LIBRARY_FUNC(jboolean, ffmpegIsAvfilterAvailable) {
  const char* requiredFilters[] = {
      "abuffer", "abuffersink", "aformat", "pan",
      "dynaudnorm", "aresample"};
  for (size_t i = 0; i < sizeof(requiredFilters) / sizeof(requiredFilters[0]);
       i++) {
    if (avfilter_get_by_name(requiredFilters[i]) == NULL) {
      LOGE("Required FFmpeg filter is missing: %s", requiredFilters[i]);
      return JNI_FALSE;
    }
  }
  return JNI_TRUE;
}

LIBRARY_FUNC(jstring, ffmpegGetEnabledFilters) {
  return env->NewStringUTF(OCTANS_ENABLED_FILTERS);
}

AUDIO_DECODER_FUNC(jlong, ffmpegInitialize, jstring codecName,
                   jbyteArray extraData, jboolean outputFloat,
                   jint rawSampleRate, jint rawChannelCount,
                   jint audioProcessingMode) {
  const AVCodec* codec = getCodecByName(env, codecName);
  if (!codec) {
    LOGE("Codec not found.");
    return 0L;
  }
  return (jlong)createDecoderContext(
      env, codec, extraData, outputFloat, rawSampleRate, rawChannelCount,
      audioProcessingMode);
}

AUDIO_DECODER_FUNC(jint, ffmpegDecode, jlong context, jobject inputData,
                   jint inputSize, jobject decoderOutputBuffer,
                   jobject outputData, jint outputSize) {
  if (!context) {
    LOGE("Context must be non-NULL.");
    return -1;
  }
  if (!inputData || !decoderOutputBuffer || !outputData) {
    LOGE("Input and output buffers must be non-NULL.");
    return -1;
  }
  if (inputSize < 0) {
    LOGE("Invalid input buffer size: %d.", inputSize);
    return -1;
  }
  if (outputSize < 0) {
    LOGE("Invalid output buffer length: %d", outputSize);
    return -1;
  }
  uint8_t* inputBuffer = (uint8_t*)env->GetDirectBufferAddress(inputData);
  uint8_t* outputBuffer = (uint8_t*)env->GetDirectBufferAddress(outputData);
  AVPacket* packet = av_packet_alloc();
  if (!packet) {
    LOGE("Failed to allocate packet.");
    return -1;
  }
  packet->data = inputBuffer;
  packet->size = inputSize;
  const int ret =
      decodePacket((OctansFfmpegAudioDecoderContext*)context, packet,
                   outputBuffer, outputSize,
                   GrowOutputBufferCallback{env, thiz, decoderOutputBuffer});
  av_packet_free(&packet);
  return ret;
}

uint8_t* GrowOutputBufferCallback::operator()(int requiredSize) const {
  jobject newOutputData = env->CallObjectMethod(
      thiz, growOutputBufferMethod, decoderOutputBuffer, requiredSize);
  if (env->ExceptionCheck()) {
    LOGE("growOutputBuffer() failed");
    env->ExceptionDescribe();
    return nullptr;
  }
  return static_cast<uint8_t*>(env->GetDirectBufferAddress(newOutputData));
}

AUDIO_DECODER_FUNC(jint, ffmpegGetChannelCount, jlong context) {
  if (!context) {
    LOGE("Context must be non-NULL.");
    return -1;
  }
  OctansFfmpegAudioDecoderContext* decoderContext =
      (OctansFfmpegAudioDecoderContext*)context;
  if (decoderContext->outputChannelLayout.nb_channels > 0) {
    return decoderContext->outputChannelLayout.nb_channels;
  }
  return decoderContext->codecContext->ch_layout.nb_channels;
}

AUDIO_DECODER_FUNC(jint, ffmpegGetSampleRate, jlong context) {
  if (!context) {
    LOGE("Context must be non-NULL.");
    return -1;
  }
  OctansFfmpegAudioDecoderContext* decoderContext =
      (OctansFfmpegAudioDecoderContext*)context;
  if (decoderContext->outputSampleRate > 0) {
    return decoderContext->outputSampleRate;
  }
  return decoderContext->codecContext->sample_rate;
}

AUDIO_DECODER_FUNC(jlong, ffmpegReset, jlong jContext, jbyteArray extraData) {
  OctansFfmpegAudioDecoderContext* decoderContext =
      (OctansFfmpegAudioDecoderContext*)jContext;
  if (!decoderContext || !decoderContext->codecContext) {
    LOGE("Tried to reset without a context.");
    return 0L;
  }

  AVCodecContext* codecContext = decoderContext->codecContext;
  AVCodecID codecId = codecContext->codec_id;
  jboolean outputFloat =
      (jboolean)(decoderContext->outputSampleFormat == OUTPUT_FORMAT_PCM_FLOAT);

  releaseFilterGraph(decoderContext);
  releaseResampleContext(decoderContext);

  if (codecId == AV_CODEC_ID_TRUEHD) {
    // Release and recreate the context if the codec is TrueHD.
    // TODO: Figure out why flushing doesn't work for this codec.
    releaseCodecContext(codecContext);
    decoderContext->codecContext = NULL;
    const AVCodec* codec = avcodec_find_decoder(codecId);
    if (!codec) {
      LOGE("Unexpected error finding codec %d.", codecId);
      releaseDecoderContext(decoderContext);
      return 0L;
    }
    decoderContext->codecContext =
        createCodecContext(env, codec, extraData, outputFloat,
                           /* rawSampleRate= */ -1,
                           /* rawChannelCount= */ -1);
    if (!decoderContext->codecContext) {
      releaseDecoderContext(decoderContext);
      return 0L;
    }
    return (jlong)decoderContext;
  }

  avcodec_flush_buffers(codecContext);
  return (jlong)decoderContext;
}

AUDIO_DECODER_FUNC(void, ffmpegRelease, jlong context) {
  if (context) {
    releaseDecoderContext((OctansFfmpegAudioDecoderContext*)context);
  }
}

const AVCodec* getCodecByName(JNIEnv* env, jstring codecName) {
  if (!codecName) {
    return NULL;
  }
  const char* codecNameChars = env->GetStringUTFChars(codecName, NULL);
  const AVCodec* codec = avcodec_find_decoder_by_name(codecNameChars);
  env->ReleaseStringUTFChars(codecName, codecNameChars);
  return codec;
}

AVCodecContext* createCodecContext(JNIEnv* env, const AVCodec* codec,
                                   jbyteArray extraData, jboolean outputFloat,
                                   jint rawSampleRate, jint rawChannelCount) {
  AVCodecContext* context = avcodec_alloc_context3(codec);
  if (!context) {
    LOGE("Failed to allocate context.");
    return NULL;
  }
  context->request_sample_fmt =
      outputFloat ? OUTPUT_FORMAT_PCM_FLOAT : OUTPUT_FORMAT_PCM_16BIT;
  if (extraData) {
    jsize size = env->GetArrayLength(extraData);
    context->extradata_size = size;
    context->extradata =
        (uint8_t*)av_malloc(size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!context->extradata) {
      LOGE("Failed to allocate extradata.");
      releaseCodecContext(context);
      return NULL;
    }
    memset(context->extradata + size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    env->GetByteArrayRegion(extraData, 0, size, (jbyte*)context->extradata);
  }
  if (context->codec_id == AV_CODEC_ID_PCM_MULAW ||
      context->codec_id == AV_CODEC_ID_PCM_ALAW) {
    context->sample_rate = rawSampleRate;
    av_channel_layout_default(&context->ch_layout, rawChannelCount);
  }
  context->err_recognition = AV_EF_IGNORE_ERR;
  int result = avcodec_open2(context, codec, NULL);
  if (result < 0) {
    logError("avcodec_open2", result);
    releaseCodecContext(context);
    return NULL;
  }
  return context;
}

OctansFfmpegAudioDecoderContext* createDecoderContext(
    JNIEnv* env, const AVCodec* codec, jbyteArray extraData,
    jboolean outputFloat, jint rawSampleRate, jint rawChannelCount,
    jint audioProcessingMode) {
  OctansFfmpegAudioDecoderContext* decoderContext =
      new OctansFfmpegAudioDecoderContext();
  memset(decoderContext, 0, sizeof(OctansFfmpegAudioDecoderContext));
  decoderContext->audioProcessingMode = audioProcessingMode;
  decoderContext->outputSampleFormat =
      outputFloat ? OUTPUT_FORMAT_PCM_FLOAT : OUTPUT_FORMAT_PCM_16BIT;
  decoderContext->resampleInputSampleFormat = AV_SAMPLE_FMT_NONE;
  decoderContext->resampleOutputSampleFormat = AV_SAMPLE_FMT_NONE;
  decoderContext->filterInputSampleFormat = AV_SAMPLE_FMT_NONE;

  if (isLocalDialogueStereoMode(audioProcessingMode)) {
    av_channel_layout_default(&decoderContext->outputChannelLayout, 2);
    decoderContext->outputSampleRate = 48000;
    if (!Java_androidx_media3_decoder_ffmpeg_FfmpegLibrary_ffmpegIsAvfilterAvailable(
            env, NULL)) {
      LOGE("Octans local dialogue stereo requested but required filters are missing.");
      releaseDecoderContext(decoderContext);
      return NULL;
    }
  } else if (audioProcessingMode != AUDIO_PROCESSING_MODE_OFF) {
    LOGE("Unsupported FFmpeg audio processing mode: %d", audioProcessingMode);
    releaseDecoderContext(decoderContext);
    return NULL;
  }

  decoderContext->codecContext =
      createCodecContext(env, codec, extraData, outputFloat, rawSampleRate,
                         rawChannelCount);
  if (!decoderContext->codecContext) {
    releaseDecoderContext(decoderContext);
    return NULL;
  }
  LOGI("Created FFmpeg audio decoder context. mode=%d outputFloat=%d",
       audioProcessingMode, outputFloat);
  return decoderContext;
}

int decodePacket(OctansFfmpegAudioDecoderContext* decoderContext,
                 AVPacket* packet, uint8_t* outputBuffer, int outputSize,
                 GrowOutputBufferCallback growBuffer) {
  AVCodecContext* codecContext = decoderContext->codecContext;
  int result = 0;
  // Queue input data.
  result = avcodec_send_packet(codecContext, packet);
  if (result) {
    logError("avcodec_send_packet", result);
    return transformError(result);
  }

  // Dequeue output data until it runs out.
  int outSize = 0;
  while (true) {
    AVFrame* frame = av_frame_alloc();
    if (!frame) {
      LOGE("Failed to allocate output frame.");
      return AUDIO_DECODER_ERROR_INVALID_DATA;
    }
    result = avcodec_receive_frame(codecContext, frame);
    if (result) {
      av_frame_free(&frame);
      if (result == AVERROR(EAGAIN)) {
        break;
      }
      logError("avcodec_receive_frame", result);
      return transformError(result);
    }

    if (isLocalDialogueStereoMode(decoderContext->audioProcessingMode)) {
      result = processFilteredFrame(decoderContext, frame, &outputBuffer,
                                    &outputSize, &outSize, growBuffer);
    } else {
      result = appendFrameToOutput(decoderContext, frame, &outputBuffer,
                                   &outputSize, &outSize, growBuffer);
    }
    av_frame_free(&frame);
    if (result < 0) {
      return result;
    }
  }
  return outSize;
}

int processFilteredFrame(OctansFfmpegAudioDecoderContext* decoderContext,
                         AVFrame* frame, uint8_t** outputBuffer,
                         int* outputSize, int* outSize,
                         GrowOutputBufferCallback growBuffer) {
  int result = ensureFilterGraph(decoderContext, frame);
  if (result < 0) {
    return transformError(result);
  }

  result = av_buffersrc_add_frame_flags(decoderContext->bufferSourceContext,
                                        frame, AV_BUFFERSRC_FLAG_KEEP_REF);
  if (result < 0) {
    logError("av_buffersrc_add_frame_flags", result);
    return transformError(result);
  }

  while (true) {
    AVFrame* filteredFrame = av_frame_alloc();
    if (!filteredFrame) {
      LOGE("Failed to allocate filtered frame.");
      return AUDIO_DECODER_ERROR_OTHER;
    }
    result = av_buffersink_get_frame(decoderContext->bufferSinkContext,
                                     filteredFrame);
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
      av_frame_free(&filteredFrame);
      break;
    }
    if (result < 0) {
      av_frame_free(&filteredFrame);
      logError("av_buffersink_get_frame", result);
      return transformError(result);
    }
    result = appendFrameToOutput(decoderContext, filteredFrame, outputBuffer,
                                 outputSize, outSize, growBuffer);
    av_frame_free(&filteredFrame);
    if (result < 0) {
      return result;
    }
  }
  return 0;
}

int appendFrameToOutput(OctansFfmpegAudioDecoderContext* decoderContext,
                        AVFrame* frame, uint8_t** outputBuffer,
                        int* outputSize, int* outSize,
                        GrowOutputBufferCallback growBuffer) {
  AVChannelLayout inputChannelLayout = {};
  if (!copyFrameChannelLayout(frame, decoderContext->codecContext,
                              &inputChannelLayout)) {
    LOGE("Unable to determine frame channel layout.");
    return AUDIO_DECODER_ERROR_OTHER;
  }
  int inputSampleRate =
      frame->sample_rate > 0 ? frame->sample_rate
                             : decoderContext->codecContext->sample_rate;
  AVSampleFormat inputSampleFormat = (AVSampleFormat)frame->format;

  setDecoderOutputFormat(decoderContext, &inputChannelLayout, inputSampleRate);

  int result = ensureResampleContext(
      decoderContext, &inputChannelLayout, inputSampleFormat, inputSampleRate,
      &inputChannelLayout, decoderContext->outputSampleFormat, inputSampleRate);
  if (result < 0) {
    av_channel_layout_uninit(&inputChannelLayout);
    return transformError(result);
  }

  int outSampleSize =
      av_get_bytes_per_sample(decoderContext->outputSampleFormat);
  int channelCount = inputChannelLayout.nb_channels;
  int outSamples =
      swr_get_out_samples(decoderContext->resampleContext, frame->nb_samples);
  if (outSamples < 0) {
    logError("swr_get_out_samples", outSamples);
    av_channel_layout_uninit(&inputChannelLayout);
    return transformError(outSamples);
  }
  int bufferOutSize = outSampleSize * channelCount * outSamples;
  if (*outSize + bufferOutSize > *outputSize) {
    LOGD(
        "Output buffer size (%d) too small for output data (%d), "
        "reallocating buffer.",
        *outputSize, *outSize + bufferOutSize);
    *outputSize = *outSize + bufferOutSize;
    *outputBuffer = growBuffer(*outputSize);
    if (!*outputBuffer) {
      LOGE("Failed to reallocate output buffer.");
      av_channel_layout_uninit(&inputChannelLayout);
      return AUDIO_DECODER_ERROR_OTHER;
    }
    *outputBuffer += *outSize;
  }

  uint8_t* convertedData[1] = {*outputBuffer};
  result = swr_convert(decoderContext->resampleContext, convertedData,
                       outSamples, (const uint8_t**)frame->data,
                       frame->nb_samples);
  av_channel_layout_uninit(&inputChannelLayout);
  if (result < 0) {
    logError("swr_convert", result);
    return AUDIO_DECODER_ERROR_INVALID_DATA;
  }
  int writtenBytes = outSampleSize * channelCount * result;
  *outputBuffer += writtenBytes;
  *outSize += writtenBytes;
  return 0;
}

int ensureFilterGraph(OctansFfmpegAudioDecoderContext* decoderContext,
                      AVFrame* frame) {
  AVChannelLayout inputChannelLayout = {};
  if (!copyFrameChannelLayout(frame, decoderContext->codecContext,
                              &inputChannelLayout)) {
    LOGE("Unable to determine filter input channel layout.");
    return AVERROR(EINVAL);
  }
  AVSampleFormat inputSampleFormat = (AVSampleFormat)frame->format;
  int inputSampleRate =
      frame->sample_rate > 0 ? frame->sample_rate
                             : decoderContext->codecContext->sample_rate;

  if (decoderContext->filterConfigured &&
      decoderContext->filterInputSampleRate == inputSampleRate &&
      decoderContext->filterInputSampleFormat == inputSampleFormat &&
      av_channel_layout_compare(&decoderContext->filterInputChannelLayout,
                                &inputChannelLayout) == 0) {
    av_channel_layout_uninit(&inputChannelLayout);
    return 0;
  }

  releaseFilterGraph(decoderContext);

  char channelLayout[CHANNEL_LAYOUT_BUFFER_LENGTH];
  int result = av_channel_layout_describe(&inputChannelLayout, channelLayout,
                                          sizeof(channelLayout));
  if (result < 0) {
    logError("av_channel_layout_describe", result);
    av_channel_layout_uninit(&inputChannelLayout);
    return result;
  }
  const char* sampleFormatName = av_get_sample_fmt_name(inputSampleFormat);
  if (!sampleFormatName) {
    LOGE("Unknown input sample format: %d", inputSampleFormat);
    av_channel_layout_uninit(&inputChannelLayout);
    return AVERROR(EINVAL);
  }

  char args[FILTER_ARGS_BUFFER_LENGTH];
  snprintf(args, sizeof(args),
           "time_base=1/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
           inputSampleRate, inputSampleRate, sampleFormatName, channelLayout);

  decoderContext->filterGraph = avfilter_graph_alloc();
  if (!decoderContext->filterGraph) {
    LOGE("Failed to allocate filter graph.");
    av_channel_layout_uninit(&inputChannelLayout);
    return AVERROR(ENOMEM);
  }

  const AVFilter* bufferSource = avfilter_get_by_name("abuffer");
  const AVFilter* bufferSink = avfilter_get_by_name("abuffersink");
  if (!bufferSource || !bufferSink) {
    LOGE("Missing abuffer or abuffersink filter.");
    av_channel_layout_uninit(&inputChannelLayout);
    return AVERROR_FILTER_NOT_FOUND;
  }

  result = avfilter_graph_create_filter(&decoderContext->bufferSourceContext,
                                        bufferSource, "in", args, NULL,
                                        decoderContext->filterGraph);
  if (result < 0) {
    logError("avfilter_graph_create_filter(abuffer)", result);
    av_channel_layout_uninit(&inputChannelLayout);
    return result;
  }

  result = avfilter_graph_create_filter(&decoderContext->bufferSinkContext,
                                        bufferSink, "out", NULL, NULL,
                                        decoderContext->filterGraph);
  if (result < 0) {
    logError("avfilter_graph_create_filter(abuffersink)", result);
    av_channel_layout_uninit(&inputChannelLayout);
    return result;
  }

  AVFilterInOut* outputs = avfilter_inout_alloc();
  AVFilterInOut* inputs = avfilter_inout_alloc();
  if (!outputs || !inputs) {
    avfilter_inout_free(&outputs);
    avfilter_inout_free(&inputs);
    av_channel_layout_uninit(&inputChannelLayout);
    return AVERROR(ENOMEM);
  }

  outputs->name = av_strdup("in");
  outputs->filter_ctx = decoderContext->bufferSourceContext;
  outputs->pad_idx = 0;
  outputs->next = NULL;

  inputs->name = av_strdup("out");
  inputs->filter_ctx = decoderContext->bufferSinkContext;
  inputs->pad_idx = 0;
  inputs->next = NULL;

  result = avfilter_graph_parse_ptr(decoderContext->filterGraph,
                                    OCTANS_LOCAL_DIALOGUE_STEREO_GRAPH, &inputs,
                                    &outputs, NULL);
  avfilter_inout_free(&inputs);
  avfilter_inout_free(&outputs);
  if (result < 0) {
    logError("avfilter_graph_parse_ptr", result);
    av_channel_layout_uninit(&inputChannelLayout);
    return result;
  }

  result = avfilter_graph_config(decoderContext->filterGraph, NULL);
  if (result < 0) {
    logError("avfilter_graph_config", result);
    av_channel_layout_uninit(&inputChannelLayout);
    return result;
  }

  av_channel_layout_copy(&decoderContext->filterInputChannelLayout,
                         &inputChannelLayout);
  decoderContext->filterInputSampleFormat = inputSampleFormat;
  decoderContext->filterInputSampleRate = inputSampleRate;
  decoderContext->filterConfigured = true;

  AVFilterLink* outputLink = decoderContext->bufferSinkContext->inputs[0];
  setDecoderOutputFormat(decoderContext, &outputLink->ch_layout,
                         outputLink->sample_rate);
  LOGI("Initialized Octans local dialogue stereo graph. inputLayout=%s "
       "inputSampleRate=%d inputSampleFormat=%s outputChannels=%d "
       "outputSampleRate=%d",
       channelLayout, inputSampleRate, sampleFormatName,
       decoderContext->outputChannelLayout.nb_channels,
       decoderContext->outputSampleRate);
  av_channel_layout_uninit(&inputChannelLayout);
  return 0;
}

bool isLocalDialogueStereoMode(int audioProcessingMode) {
  return audioProcessingMode == AUDIO_PROCESSING_MODE_LOCAL_DIALOGUE_STEREO;
}

int ensureResampleContext(OctansFfmpegAudioDecoderContext* decoderContext,
                          const AVChannelLayout* inputChannelLayout,
                          AVSampleFormat inputSampleFormat,
                          int inputSampleRate,
                          const AVChannelLayout* outputChannelLayout,
                          AVSampleFormat outputSampleFormat,
                          int outputSampleRate) {
  if (decoderContext->resampleConfigured &&
      decoderContext->resampleInputSampleRate == inputSampleRate &&
      decoderContext->resampleOutputSampleRate == outputSampleRate &&
      decoderContext->resampleInputSampleFormat == inputSampleFormat &&
      decoderContext->resampleOutputSampleFormat == outputSampleFormat &&
      av_channel_layout_compare(&decoderContext->resampleInputChannelLayout,
                                inputChannelLayout) == 0 &&
      av_channel_layout_compare(&decoderContext->resampleOutputChannelLayout,
                                outputChannelLayout) == 0) {
    return 0;
  }

  releaseResampleContext(decoderContext);
  av_channel_layout_copy(&decoderContext->resampleInputChannelLayout,
                         inputChannelLayout);
  av_channel_layout_copy(&decoderContext->resampleOutputChannelLayout,
                         outputChannelLayout);
  decoderContext->resampleInputSampleFormat = inputSampleFormat;
  decoderContext->resampleOutputSampleFormat = outputSampleFormat;
  decoderContext->resampleInputSampleRate = inputSampleRate;
  decoderContext->resampleOutputSampleRate = outputSampleRate;

  int result = swr_alloc_set_opts2(&decoderContext->resampleContext,
                                   &decoderContext->resampleOutputChannelLayout,
                                   outputSampleFormat, outputSampleRate,
                                   &decoderContext->resampleInputChannelLayout,
                                   inputSampleFormat, inputSampleRate,
                                   0, NULL);
  if (result < 0) {
    logError("swr_alloc_set_opts2", result);
    releaseResampleContext(decoderContext);
    return result;
  }
  result = swr_init(decoderContext->resampleContext);
  if (result < 0) {
    logError("swr_init", result);
    releaseResampleContext(decoderContext);
    return result;
  }
  decoderContext->resampleConfigured = true;
  return 0;
}

bool copyFrameChannelLayout(AVFrame* frame, AVCodecContext* codecContext,
                            AVChannelLayout* out) {
  if (frame->ch_layout.nb_channels > 0) {
    return av_channel_layout_copy(out, &frame->ch_layout) == 0;
  }
  if (codecContext->ch_layout.nb_channels > 0) {
    return av_channel_layout_copy(out, &codecContext->ch_layout) == 0;
  }
  return false;
}

void setDecoderOutputFormat(OctansFfmpegAudioDecoderContext* decoderContext,
                            const AVChannelLayout* channelLayout,
                            int sampleRate) {
  if (channelLayout->nb_channels > 0 &&
      av_channel_layout_compare(&decoderContext->outputChannelLayout,
                                channelLayout) != 0) {
    av_channel_layout_uninit(&decoderContext->outputChannelLayout);
    av_channel_layout_copy(&decoderContext->outputChannelLayout, channelLayout);
  }
  if (sampleRate > 0) {
    decoderContext->outputSampleRate = sampleRate;
  }
}

int transformError(int errorNumber) {
  return errorNumber == AVERROR_INVALIDDATA ? AUDIO_DECODER_ERROR_INVALID_DATA
                                            : AUDIO_DECODER_ERROR_OTHER;
}

void logError(const char* functionName, int errorNumber) {
  char* buffer = (char*)malloc(ERROR_STRING_BUFFER_LENGTH * sizeof(char));
  av_strerror(errorNumber, buffer, ERROR_STRING_BUFFER_LENGTH);
  LOGE("Error in %s: %s", functionName, buffer);
  free(buffer);
}

void logChannelLayout(const char* label, const AVChannelLayout* channelLayout) {
  char buffer[CHANNEL_LAYOUT_BUFFER_LENGTH];
  if (av_channel_layout_describe(channelLayout, buffer, sizeof(buffer)) >= 0) {
    LOGD("%s channel layout: %s", label, buffer);
  }
}

void releaseFilterGraph(OctansFfmpegAudioDecoderContext* decoderContext) {
  if (!decoderContext) {
    return;
  }
  if (decoderContext->filterGraph) {
    avfilter_graph_free(&decoderContext->filterGraph);
  }
  decoderContext->bufferSourceContext = NULL;
  decoderContext->bufferSinkContext = NULL;
  if (decoderContext->filterConfigured) {
    av_channel_layout_uninit(&decoderContext->filterInputChannelLayout);
  }
  decoderContext->filterInputSampleFormat = AV_SAMPLE_FMT_NONE;
  decoderContext->filterInputSampleRate = 0;
  decoderContext->filterConfigured = false;
}

void releaseResampleContext(OctansFfmpegAudioDecoderContext* decoderContext) {
  if (!decoderContext) {
    return;
  }
  if (decoderContext->resampleContext) {
    swr_free(&decoderContext->resampleContext);
  }
  if (decoderContext->resampleConfigured) {
    av_channel_layout_uninit(&decoderContext->resampleInputChannelLayout);
    av_channel_layout_uninit(&decoderContext->resampleOutputChannelLayout);
  }
  decoderContext->resampleInputSampleFormat = AV_SAMPLE_FMT_NONE;
  decoderContext->resampleOutputSampleFormat = AV_SAMPLE_FMT_NONE;
  decoderContext->resampleInputSampleRate = 0;
  decoderContext->resampleOutputSampleRate = 0;
  decoderContext->resampleConfigured = false;
}

void releaseCodecContext(AVCodecContext* context) {
  if (!context) {
    return;
  }
  avcodec_free_context(&context);
}

void releaseDecoderContext(OctansFfmpegAudioDecoderContext* decoderContext) {
  if (!decoderContext) {
    return;
  }
  releaseFilterGraph(decoderContext);
  releaseResampleContext(decoderContext);
  if (decoderContext->outputChannelLayout.nb_channels > 0) {
    av_channel_layout_uninit(&decoderContext->outputChannelLayout);
  }
  releaseCodecContext(decoderContext->codecContext);
  decoderContext->codecContext = NULL;
  delete decoderContext;
}
