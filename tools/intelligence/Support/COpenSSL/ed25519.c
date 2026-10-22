#include "COpenSSL.h"
#include <openssl/evp.h>

int black_god_ed25519_verify(const uint8_t public_key[32], const uint8_t *message, size_t message_count,
                             const uint8_t *signature, size_t signature_count) {
    if (public_key == NULL || signature == NULL || signature_count != 64) return 0;
    static const uint8_t empty = 0;
    if (message == NULL) message = &empty;
    EVP_PKEY *key = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, public_key, 32);
    if (key == NULL) return -1;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    int result = -1;
    if (ctx != NULL && EVP_DigestVerifyInit(ctx, NULL, NULL, NULL, key) == 1) {
        result = EVP_DigestVerify(ctx, signature, signature_count, message, message_count) == 1 ? 1 : 0;
    }
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(key);
    return result;
}
