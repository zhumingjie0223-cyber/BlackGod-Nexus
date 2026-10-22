#ifndef BLACK_GOD_C_OPENSSL_H
#define BLACK_GOD_C_OPENSSL_H
#include <stddef.h>
#include <stdint.h>
int black_god_sha256(const uint8_t *data, size_t count, uint8_t digest[32]);
/* Ed25519 verify via EVP_DigestVerify. Returns 1 valid, 0 invalid, -1 error. Verify only; no key generation. */
int black_god_ed25519_verify(const uint8_t public_key[32], const uint8_t *message, size_t message_count,
                             const uint8_t *signature, size_t signature_count);
#endif
