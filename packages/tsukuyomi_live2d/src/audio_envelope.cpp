#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#define DR_MP3_IMPLEMENTATION
#define DR_MP3_NO_STDIO
#include "vendor/dr_libs/dr_mp3.h"
#define DR_WAV_IMPLEMENTATION
#define DR_WAV_NO_STDIO
#include "vendor/dr_libs/dr_wav.h"
#if defined(_WIN32)
#define AUDIO_API extern "C" __declspec(dllexport)
#else
#define AUDIO_API extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif

// Bounded in-memory decoding into 20 ms PCM windows, independent of playback.
AUDIO_API int32_t ts_audio_envelope(const uint8_t* bytes, int32_t size,
                                  float* levels, int32_t capacity,
                                  double* duration_ms) {
  if (!bytes || size <= 0 || size > 40 * 1024 * 1024 || !levels ||
      capacity <= 0 || capacity > 30000 || !duration_ms) return -1;
  drmp3 mp3{};
  drwav wav{};
  const bool is_wav = size >= 12 && std::memcmp(bytes, "RIFF", 4) == 0 &&
                      std::memcmp(bytes + 8, "WAVE", 4) == 0;
  uint32_t rate, channels;
  if (is_wav) {
    if (!drwav_init_memory(&wav, bytes, static_cast<size_t>(size), nullptr)) return -1;
    rate = wav.sampleRate; channels = wav.channels;
  } else {
    if (!drmp3_init_memory(&mp3, bytes, static_cast<size_t>(size), nullptr)) return -1;
    rate = mp3.sampleRate; channels = mp3.channels;
  }
  const auto cleanup = [&]() { if (is_wav) drwav_uninit(&wav); else drmp3_uninit(&mp3); };
  if (rate < 8000 || rate > 192000 || channels < 1 || channels > 8) {
    cleanup(); return -1;
  }
  const uint32_t window = std::max<uint32_t>(1, static_cast<uint32_t>(std::round(rate * .02)));
  float samples[2048 * 8];
  uint64_t frames = 0;
  uint32_t within_window = 0;
  double sum = 0;
  int32_t count = 0;
  bool done = false;
  while (!done && count < capacity) {
    const uint64_t read = is_wav ? drwav_read_pcm_frames_f32(&wav, 2048, samples)
                                : drmp3_read_pcm_frames_f32(&mp3, 2048, samples);
    if (!read) break;
    for (uint64_t f = 0; f < read; f++) {
      for (uint32_t c = 0; c < channels; c++) {
        const float value = samples[f * channels + c];
        if (std::isfinite(value)) sum += static_cast<double>(value) * value;
      }
      ++frames; ++within_window;
      if (within_window == window) {
        levels[count++] = std::min(1.0, std::sqrt(sum / (within_window * channels)) * 3.2);
        sum = 0; within_window = 0;
        if (count == capacity) { done = true; break; }
      }
    }
  }
  if (within_window && count < capacity) {
    levels[count++] = std::min(1.0, std::sqrt(sum / (within_window * channels)) * 3.2);
  }
  *duration_ms = frames * 1000.0 / rate;
  cleanup();
  return count ? count : -1;
}
