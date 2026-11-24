// Fuzz the HTTP helpers HttpRetryRequest uses on server-controlled data (lib/trmnl/src/http_utils.cpp),
// in the order src/services/http_retry_request.cpp uses them: the response's HTTP status code fed to
// the fast-retry policy, a redirect's Location header resolved against the request URL's origin, the
// same-origin check that decides whether auth headers go to the redirect hop, and the content-type
// sniffing of the downloaded image body.
// Input: <status code> [<https_request_err_e>]\n<request url>\n<Location header>\n<body bytes...>
#include <http_utils.h>
#include <stdint.h>
#include <stdlib.h>
#include <string>

// Next '\n'-terminated field of `in` starting at `pos`; `pos` moves past the newline.
static std::string field(const std::string &in, size_t &pos) {
  if (pos >= in.size()) return std::string();
  size_t nl = in.find('\n', pos);
  if (nl == std::string::npos) nl = in.size();
  std::string out = in.substr(pos, nl - pos);
  pos = nl + 1;
  return out;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  std::string in(reinterpret_cast<const char *>(data), size);
  size_t pos = 0;
  std::string status = field(in, pos);
  std::string url = field(in, pos);
  std::string location = field(in, pos);

  // Status line: the HTTP code (negative = HTTPClient transport error) and the request's error code.
  char *end = nullptr;
  long code = strtol(status.c_str(), &end, 10);
  long err = strtol(end, nullptr, 10);
  if (err < HTTPS_NO_ERR || err > HTTPS_IMAGE_DOWNLOAD_FAILED) err = HTTPS_RESPONSE_CODE_INVALID;
  (void)shouldFastRetry((int)code, (https_request_err_e)err);

  String u(url.c_str()), loc(location.c_str());
  String origin = httpOriginOf(u);
  String next = resolveRedirectLocation(loc, origin);
  (void)isSameOrigin(next, origin);
  (void)isSameOrigin(next, u);

  const uint8_t *body = pos < size ? data + pos : data + size;
  (void)sniffImageContentType(body, size - (body - data));
  return 0;
}
