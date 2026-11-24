// Fuzz the JSON parsers for the server's /api/display and /api/setup responses
// (lib/trmnl parse_response_api_display.cpp / parse_response_api_setup.cpp, ArduinoJson).
// The firmware reads the HTTP body into a String and hands it to these functions.
#include <api_response_parsing.h>
#include <stdint.h>
#include <string.h>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  std::string body(reinterpret_cast<const char *>(data), size); // String is NUL-terminated
  String payload(body.c_str());
  ApiDisplayResponse d = parseResponse_apiDisplay(payload);
  (void)d;
  String payload2(body.c_str());
  ApiSetupResponse s = parseResponse_apiSetup(payload2);
  (void)s;
  return 0;
}
