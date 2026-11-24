// Minimal host Arduino.h for the image-render harness (mayhem/). The firmware's render code only
// needs integer types and libc; bb_epaper/PNGdec/JPEGDEC are built in their non-Arduino (__LINUX__)
// mode, which declares delay/pinMode/HIGH/LOW itself.
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#ifndef PROGMEM
#define PROGMEM
#endif
#ifndef RTC_DATA_ATTR
#define RTC_DATA_ATTR
#endif
