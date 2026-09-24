#ifndef SENSORIUM_COPENSSL_SHIM_H
#define SENSORIUM_COPENSSL_SHIM_H

#include <openssl/evp.h>
#include <openssl/obj_mac.h>
#include <openssl/rand.h>
#include <openssl/err.h>
#include <openssl/crypto.h>
#include <openssl/opensslv.h>
#include <openssl/ssl.h>
#include <openssl/bio.h>
#include <openssl/x509.h>

// The QUIC client API and the EVP one-shot calls this port uses are
// OpenSSL 3 APIs.
#if OPENSSL_VERSION_NUMBER < 0x30000000L
#error "Sensorium requires OpenSSL 3.0 or newer"
#endif

// SSL_set_tlsext_host_name is a function-like macro over SSL_ctrl, which no
// Swift importer can see. Wrapping it keeps the call site in Swift honest
// about what it is setting.
static inline int sensorium_ssl_set_tlsext_host_name(SSL *ssl, const char *name)
{
    return (int)SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, (void *)name);
}

#endif
