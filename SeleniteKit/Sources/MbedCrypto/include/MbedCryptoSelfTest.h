#pragma once
#include <stdbool.h>

// AES-128-GCM known-answer test (McGrew and Viega test case 2) through the PSA API.
bool sel_mbedcrypto_gcm_selftest(void);
