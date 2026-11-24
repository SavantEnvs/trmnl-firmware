// Built twice by mayhem/build.sh: as the original TRMNL (BOARD_TRMNL, target image_render) and as
// the 4-colour TRMNL (BOARD_TRMNL_4CLR, target image_render_4clr, which has png_draw_4clr).
//
// Fuzz the firmware's image draw path: the bytes the server sends as the screen image (PNG, JPEG,
// Group5 or BMP) decoded into the bb_epaper panel driver, as src/display.cpp draw_image() does.
//
// Input layout:  [device][temp profile][image bytes...]
//   device       picks an entry of src/board_config.cpp device_list (mono, 4-gray, 3/4-colour and
//                Spectra-6 panels), as hw_config_init(DEVICE_MODEL) does at boot
//   temp profile iTempProfile (0..2), as the server's temp_profile sets it
//
// bb_epaper is built with -D__MEM_ONLY__, so panel I/O is a no-op and frames land in RAM.
// State kept across inputs: the global BBEPAPER object, re-initialised for every input by
// display_select_one_bit_panel()'s own sequence, and every buffer it allocates is freed.
#include <Group5.h>
#include <PNGdec.h>
#include <board_config.h>
#include <bmp.h>
#include <epd_driver.h>
#include <globals.h>
#include <jpeg_render.h>
#include <png_flip.h>
#include <png_render.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <trmnl_log.h>

// Globals the firmware defines in display.cpp / globals.cpp
BBEPAPER bbep;
int iUpdateCount = 0;
uint32_t iTempProfile = 0;

// The device names of src/board_config.cpp device_list (BB_EPAPER boards); device_list itself has
// internal linkage, so the harness selects a device by name through hw_config_init(), as boot does.
static const char *const kDevices[] = {
    "og", "og_4clr", "og_gen2", "og_gen2_4clr", "xteink_x4", "xteink_x3", "waveshare", "waveshare_397",
    "seeed_sticky", "seeed_sticky_b", "seeed_esp32c3", "seeed_esp32s3", "xiao_epaper_mini",
    "xiao_epaper_mini_b", "xiao_epaper_display", "xiao_epaper_3clr", "xiao_epaper_6clr",
    "reterminal_e1001", "reterminal_e1002", "photo_painter", "crowpanel42", "m5_paper_mono",
    "m5_paper_color", "reterminal_e1004", "trmnl_steam", "zectrix_note4", "zectrix_note4c"};
static const int kNumDevices = sizeof(kDevices) / sizeof(kDevices[0]);

// Logging goes nowhere (the firmware sends it to the serial port / NVS)
void log_impl(LogLevel, LogMode, const char *, int, const char *, ...) {}
void set_verbose_logging(bool) {}
bool get_verbose_logging() { return false; }
bool read_verbose_logging() { return false; }
void write_verbose_logging(bool) {}

// src/display.cpp display_select_one_bit_panel()
static void select_one_bit_panel() {
  bool custom_pins = pDevice->epd_mosi_pin != 0 || pDevice->epd_sck_pin != 0;
  int one_bit = dpList[pDevice->panel_set][custom_pins ? iTempProfile : 0].OneBit;
  if (custom_pins) {
    bbep.setPanelType(one_bit);
    bbep.initIO(pDevice->epd_dc_pin, pDevice->epd_rst_pin, pDevice->epd_busy_pin, pDevice->epd_cs_pin,
                pDevice->epd_mosi_pin, pDevice->epd_sck_pin, 8000000);
  } else {
    bbep.begin(one_bit);
  }
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 2 + 4) return -1;
  pDevice = NULL;
  hw_config_init(kDevices[data[0] % kNumDevices]);
  if (!pDevice) abort(); // every name above is in device_list
  iTempProfile = data[1] % 3;
  iUpdateCount = 0;
  data += 2;
  size -= 2;
  if (size > MAX_IMAGE_SIZE) return -1; // display_session.cpp refuses larger downloads

  bbep.setBuffer(NULL);
  bbep.setMemoryMode(BBEP_MODE_NATIVE);
  select_one_bit_panel();

  // display_session.cpp hands display_show_image() a malloc'd buffer of the downloaded size
  uint8_t *image = (uint8_t *)malloc(size);
  memcpy(image, data, size);
  int data_size = (int)size;
  // draw_image()'s MOTOLONG/MOTOSHORT magic checks, as big-endian reads
  bool isPNG = ((uint32_t)image[0] << 24 | image[1] << 16 | image[2] << 8 | image[3]) == 0x89504e47;

  if (isPNG && data_size < MAX_IMAGE_SIZE) {
    png_to_epd(image, data_size, false);
  } else if ((image[0] << 8 | image[1]) == 0xffd8) {
    jpeg_to_epd(image, data_size);
  } else if (*(uint16_t *)image == BB_BITMAP_MARKER) {
    // Group5-compressed image
    BB_BITMAP *pBBB = (BB_BITMAP *)image;
    bbep.setMemoryMode(BBEP_MODE_1BPP);
    if (data_size >= (int)sizeof(BB_BITMAP) && bbep.allocBuffer(false) == BBEP_SUCCESS) {
      int x = bbep.width() - pBBB->width;
      int y = bbep.height() - pBBB->height;
      if (x > 0 || y > 0) bbep.fillScreen(BBEP_WHITE);
      bbep.loadG5Image(image, x, y, BBEP_WHITE, BBEP_BLACK);
      bbep.writePlane();
      bbep.freeBuffer();
    }
  } else if (data_size >= 62) {
    // BMP: display_session.cpp reads it into a DISPLAY_BMP_IMAGE_SIZE buffer and only draws it
    // once parseBMPHeader() accepts it (800x480, 1 bpp, 2-colour palette)
    uint8_t *bmp = (uint8_t *)calloc(1, DISPLAY_BMP_IMAGE_SIZE);
    memcpy(bmp, image, data_size < DISPLAY_BMP_IMAGE_SIZE ? data_size : DISPLAY_BMP_IMAGE_SIZE);
    bool reversed = false;
    if (parseBMPHeader(bmp, reversed) == BMP_NO_ERR) {
      const int w = bmp[18] | (bmp[19] << 8);
      const int h = bmp[22] | (bmp[23] << 8);
      bmpNormalizePolarity(bmp, bmp + 62, (w / 8) * h);
      flip_image(bmp + 62, w, h, false);
      bbep.setMemoryMode(BBEP_MODE_1BPP);
      bbep.setBuffer(bmp + 62);
      bbep.writePlane();
      bbep.setBuffer(NULL);
    }
    free(bmp);
  }
  bbep.freeBuffer();
  free(image);
  return 0;
}
