#ifndef LSS_QRGEN_H
#define LSS_QRGEN_H
#include <stdint.h>

// Minimal QR encoder: byte mode, ECC level M, auto version 1-3 (single block).
// ponytail: caps at 42 bytes (v3-M). Our token is 32 hex; longer custom tokens
// return 0 and the UI falls back to the text label. Bump versions if needed.
// Writes an N*N matrix of 0/1 into `modules` (needs >= 29*29 bytes).
// Returns N (side length) on success, 0 if data too long.
int lss_qr_encode(const uint8_t *data, int len, uint8_t *modules);

#endif
