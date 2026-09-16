#pragma once

#include <stddef.h>
#include <stdint.h>

constexpr uint32_t CHIRP_SAMPLE_RATE = 24000;
constexpr size_t CHIRP_SAMPLE_COUNT = 14400;  // 600 ms at 24 kHz

// One cycle of a 1 kHz sine wave at 24 kHz, with a peak of exactly 8,192.
constexpr int16_t TONE_CYCLE[] = {
    0,     2120,  4096,  5793,  7094,  7913,  8192,  7913,
    7094,  5793,  4096,  2120,  0,     -2120, -4096, -5793,
    -7094, -7913, -8192, -7913, -7094, -5793, -4096, -2120,
};
constexpr size_t TONE_CYCLE_SAMPLES =
    sizeof(TONE_CYCLE) / sizeof(TONE_CYCLE[0]);
