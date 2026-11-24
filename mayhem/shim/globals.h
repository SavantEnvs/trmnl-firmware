// Host stand-in for include/globals.h, used only by the image-render harness: the real header
// pulls in Preferences, esp_sleep, the API client and OTA service, none of which the render
// code touches. It declares just the globals src/png_render.cpp and src/jpeg_render.cpp read.
#pragma once
#include <Arduino.h>
#include <config.h>
extern int iUpdateCount;
extern uint32_t iTempProfile;
