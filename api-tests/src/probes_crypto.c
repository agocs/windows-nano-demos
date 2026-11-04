/* probes_crypto.c - bcrypt, ncrypt and crypt32 probes. */
#include "probes.h"
#include <wincrypt.h>

typedef LONG (WINAPI *BCryptGenRandom_t)(void *, BYTE *, ULONG, ULONG);
typedef LONG (WINAPI *BCryptOpenAlgorithmProvider_t)(void **, LPCWSTR, LPCWSTR, ULONG);
typedef LONG (WINAPI *BCryptHash_t)(void *, BYTE *, ULONG, BYTE *, ULONG, BYTE *, ULONG);
typedef LONG (WINAPI *BCryptCloseAlgorithmProvider_t)(void *, ULONG);
typedef LONG (WINAPI *NCryptOpenStorageProvider_t)(ULONG_PTR *, LPCWSTR, DWORD);
typedef LONG (WINAPI *NCryptFreeObject_t)(ULONG_PTR);

static void p_BCryptGenRandom(result_t *r)
{
    NEEDT("bcrypt", BCryptGenRandom_t, BCryptGenRandom);
    BYTE buf[32];
    memset(buf, 0, sizeof buf);
    LONG st = BCryptGenRandom(NULL, buf, sizeof buf, 0x2 /* BCRYPT_USE_SYSTEM_PREFERRED_RNG */);
    if (st) { fail_code(r, (DWORD)st, "NTSTATUS 0x%08lx", (unsigned long)st); return; }
    int nz = 0;
    for (int i = 0; i < 32; i++) nz += buf[i] != 0;
    if (nz < 8) fail_code(r, 0, "random bytes look empty");
    else ok(r, "32 random bytes");
}

static void p_BCryptHash(result_t *r)
{
    NEEDT("bcrypt", BCryptOpenAlgorithmProvider_t, BCryptOpenAlgorithmProvider);
    NEEDT("bcrypt", BCryptHash_t, BCryptHash);
    NEEDT("bcrypt", BCryptCloseAlgorithmProvider_t, BCryptCloseAlgorithmProvider);
    void *alg = NULL;
    LONG st = BCryptOpenAlgorithmProvider(&alg, L"SHA256", NULL, 0);
    if (st) { fail_code(r, (DWORD)st, "BCryptOpenAlgorithmProvider NTSTATUS 0x%08lx", (unsigned long)st); return; }
    BYTE out[32];
    st = BCryptHash(alg, NULL, 0, (BYTE *)"abc", 3, out, sizeof out);
    BCryptCloseAlgorithmProvider(alg, 0);
    static const BYTE want[32] = { 0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
                                   0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad };
    if (st) fail_code(r, (DWORD)st, "BCryptHash NTSTATUS 0x%08lx", (unsigned long)st);
    else if (memcmp(out, want, 32)) fail_code(r, 0, "wrong digest");
    else ok(r, "SHA-256(abc) matches");
}

static void p_NCryptOpenStorageProvider(result_t *r)
{
    NEEDT("ncrypt", NCryptOpenStorageProvider_t, NCryptOpenStorageProvider);
    NEEDT("ncrypt", NCryptFreeObject_t, NCryptFreeObject);
    ULONG_PTR h = 0;
    LONG st = NCryptOpenStorageProvider(&h, L"Microsoft Software Key Storage Provider", 0);
    if (st) { fail_code(r, (DWORD)st, "SECURITY_STATUS 0x%08lx", (unsigned long)st); return; }
    NCryptFreeObject(h);
    ok(r, "MS_KEY_STORAGE_PROVIDER opened");
}

static void p_CertEnumCertificatesInStore(result_t *r)
{
    NEED("crypt32", CertOpenSystemStoreW);
    NEED("crypt32", CertEnumCertificatesInStore);
    NEED("crypt32", CertCloseStore);
    HCERTSTORE s = CertOpenSystemStoreW(0, L"ROOT");
    if (!s) { fail(r, "CertOpenSystemStoreW(ROOT)"); return; }
    int n = 0;
    PCCERT_CONTEXT c = NULL;
    while ((c = CertEnumCertificatesInStore(s, c)) != NULL) n++;
    CertCloseStore(s, 0);
    if (!n) fail_code(r, 0, "ROOT store is empty");
    else ok(r, "%d root certificates", n);
}

static void p_CryptStringToBinaryA(result_t *r)
{
    NEED("crypt32", CryptStringToBinaryA);
    BYTE out[16];
    DWORD n = sizeof out;
    if (!CryptStringToBinaryA("aGVsbG8=", 0, CRYPT_STRING_BASE64, out, &n, NULL, NULL)) { fail(r, "CryptStringToBinaryA"); return; }
    if (n != 5 || memcmp(out, "hello", 5)) fail_code(r, 0, "wrong decode");
    else ok(r, "base64 aGVsbG8= is hello");
}

const probe_t probes_crypto[] = {
    PROBE(bcrypt, BCryptGenRandom, "system preferred RNG", 0, p_BCryptGenRandom),
    PROBE(bcrypt, BCryptHash, "SHA-256 of abc", 0, p_BCryptHash),
    PROBE(ncrypt, NCryptOpenStorageProvider, "MS_KEY_STORAGE_PROVIDER", 0, p_NCryptOpenStorageProvider),
    PROBE(crypt32, CertEnumCertificatesInStore, "ROOT store has certificates", 0, p_CertEnumCertificatesInStore),
    PROBE(crypt32, CryptStringToBinaryA, "CRYPT_STRING_BASE64 decode", 0, p_CryptStringToBinaryA),
    PROBE_END
};
