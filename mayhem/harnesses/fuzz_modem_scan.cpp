// Fuzz the ESP-AT +CWLAP Wi-Fi scan parser (lib/trmnl/src/modem_scan_parse.cpp). The modem's
// reply carries SSIDs chosen by whoever runs a nearby access point.
#include <modem_scan_parse.h>
#include <stdint.h>
#include <string>
#include <wifi_auth.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  std::string raw(reinterpret_cast<const char *>(data), size);
  String reply(raw.c_str());
  std::vector<ParsedModemNetwork> nets = parseCwlapResponse(reply);
  for (auto &n : nets) (void)n.ssid.length();
  return 0;
}
