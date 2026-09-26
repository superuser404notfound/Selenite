#include <psa/crypto.h>
#include <string.h>
#include "include/MbedCryptoSelfTest.h"

bool sel_mbedcrypto_gcm_selftest(void) {
    if (psa_crypto_init() != PSA_SUCCESS) {
        return false;
    }
    static const uint8_t key[16] = {0};
    static const uint8_t iv[12] = {0};
    static const uint8_t plaintext[16] = {0};
    static const uint8_t expected[32] = {
        0x03, 0x88, 0xda, 0xce, 0x60, 0xb6, 0xa3, 0x92, 0xf3, 0x28, 0xc2, 0xb9, 0x71, 0xb2, 0xfe, 0x78,
        0xab, 0x6e, 0x47, 0xd4, 0x2c, 0xec, 0x13, 0xbd, 0xf5, 0x3a, 0x67, 0xb2, 0x12, 0x57, 0xbd, 0xdf,
    };
    psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attributes, PSA_KEY_TYPE_AES);
    psa_set_key_bits(&attributes, 128);
    psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_ENCRYPT);
    psa_set_key_algorithm(&attributes, PSA_ALG_GCM);
    psa_key_id_t keyId;
    if (psa_import_key(&attributes, key, sizeof(key), &keyId) != PSA_SUCCESS) {
        return false;
    }
    uint8_t output[32];
    size_t outputLength = 0;
    psa_status_t status = psa_aead_encrypt(keyId, PSA_ALG_GCM, iv, sizeof(iv), NULL, 0,
                                           plaintext, sizeof(plaintext), output, sizeof(output), &outputLength);
    psa_destroy_key(keyId);
    return status == PSA_SUCCESS && outputLength == 32 && memcmp(output, expected, 32) == 0;
}
