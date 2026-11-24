// bb_epaper (pinned in platformio.ini) built in its memory-only mode for the host: panel I/O is a
// no-op and frames are drawn into RAM. At this pin mem_io.inl lacks bbepWriteCmdData(), which
// bb_ep.inl calls, so this wrapper declares it and supplies the same no-op stub the other
// mem_io.inl I/O functions are.
#include "bb_epaper.h"
void bbepWriteCmdData(BBEPDISP *pBBEP, uint8_t cmd, uint8_t *pData, int iLen);
#include "bb_epaper.cpp"
void bbepWriteCmdData(BBEPDISP *pBBEP, uint8_t cmd, uint8_t *pData, int iLen) {
  (void)pBBEP;
  (void)cmd;
  (void)pData;
  (void)iLen;
}
