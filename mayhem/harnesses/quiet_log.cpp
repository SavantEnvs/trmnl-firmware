// Host logging sink for the lib/trmnl harnesses: the firmware's log_impl sends to serial/NVS and
// lib/trmnl/src/test_logger.cpp printf()s every line; a fuzzer only needs the calls to go nowhere.
#include <trmnl_log.h>
void log_impl(LogLevel, LogMode, const char *, int, const char *, ...) {}
void set_verbose_logging(bool) {}
bool get_verbose_logging() { return false; }
bool read_verbose_logging() { return false; }
void write_verbose_logging(bool) {}
