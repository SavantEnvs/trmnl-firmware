// Fuzz the log store (lib/trmnl/src/stored_logs.cpp) and the log serializers
// (serialize_request_api_log.cpp). Stored log lines include server-derived text (URLs, error
// details), are kept in an NVS ring buffer and are later JSON-serialized for /api/log.
// Input: [old_count][new_count] then log lines separated by '\n'. The persistence is the
// in-memory fake the upstream unit tests use (test/common/memory_persistence.cpp), fresh per input.
#include <api_request_serialization.h>
#include <memory_persistence.h>
#include <stdint.h>
#include <stored_logs.h>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 2) return -1;
  MemoryPersistence persistence;
  StoredLogs logs(data[0] % 8, data[1] % 8, "log_", "log_head", persistence);
  std::string rest(reinterpret_cast<const char *>(data + 2), size - 2);
  size_t pos = 0;
  while (pos <= rest.size()) {
    size_t eol = rest.find('\n', pos);
    if (eol == std::string::npos) eol = rest.size();
    String line(rest.substr(pos, eol - pos).c_str());
    logs.store_log(line);
    pos = eol + 1;
  }
  String all = logs.gather_stored_logs();
  String req = serializeApiLogRequest(all);
  (void)req.length();
  (void)logs.get_overwrite_count();
  logs.clear_stored_logs();
  return 0;
}
