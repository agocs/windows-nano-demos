/* probes.h - shared types and helpers for apiprobe L3 probes.
 *
 * Rules for every probe (see api-tests/README.md):
 *  - resolve every function under test with NEED()/NEEDT(); never call it
 *    directly, so apiprobe.exe only imports kernel32.dll and msvcrt.dll and a
 *    missing API becomes missing-dll / missing-export instead of a crash;
 *  - clean up temp files (%TEMP%\apiprobe\<id>), registry keys
 *    (HKCU\Software\apiprobe), sockets and handles;
 *  - no network I/O unless needs_network is set (then g_network says whether
 *    --network was given; the runner reports skip otherwise);
 *  - never block on UI: no MessageBox, message-only windows only.
 */
#ifndef APIPROBE_PROBES_H
#define APIPROBE_PROBES_H

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef WINVER
#define WINVER 0x0A00
#endif
#ifndef NTDDI_VERSION
#define NTDDI_VERSION 0x0A000006
#endif
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <winsock2.h> /* before windows.h, so winsock.h is not pulled in */
#include <windows.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* Severity order: a move to the right is a regression. */
typedef enum {
    ST_OK = 0,
    ST_SKIP,
    ST_ERROR,
    ST_MISSING_EXPORT,
    ST_MISSING_DLL,
    ST_TIMEOUT,
    ST_CRASH,
    ST_COUNT
} status_t;

typedef struct {
    status_t status;
    DWORD win32_error;
    char detail[512];
} result_t;

typedef void (*probe_fn)(result_t *r);

typedef struct {
    const char *id;       /* "<dll>.<Function>", unique */
    const char *dll;      /* "kernel32" */
    const char *function; /* "CreateFileW" */
    const char *check;    /* what the probe checks */
    int needs_network;
    probe_fn fn;          /* NULL: load and resolve only */
} probe_t;

#define PROBE(dll, func, check, net, fn) { #dll "." #func, #dll, #func, check, net, fn }
/* Explicit id, for several probes of one function. */
#define PROBE_ID(id, dll, func, check, net, fn) { id, dll, func, check, net, fn }
/* Load only: no export is resolved and no behaviour is checked. */
#define PROBE_LOAD(dll) { #dll ".load", #dll, "", "loads", 0, NULL }
#define PROBE_END { NULL, NULL, NULL, NULL, 0, NULL }

extern int g_network;

/* Loads dll (System32 search) and resolves name; on failure sets r->status to
 * ST_MISSING_DLL or ST_MISSING_EXPORT and returns NULL. */
void *need_(result_t *r, const char *dll, const char *name);

/* Declares a local function pointer that shadows the real declaration, so the
 * probe body reads like ordinary code: NEED("kernel32", CreateFileW); */
#define NEED(dll, fn) __typeof__(&fn) fn = need_(r, dll, #fn); if (!fn) return
/* Same, for functions the MinGW headers do not declare. */
#define NEEDT(dll, type, fn) type fn = (type)need_(r, dll, #fn); if (!fn) return

/* Result helpers. fail() records GetLastError() as it was on entry. */
void ok(result_t *r, const char *fmt, ...);
void fail(result_t *r, const char *fmt, ...);
void fail_code(result_t *r, DWORD code, const char *fmt, ...);
void skip(result_t *r, const char *fmt, ...);

/* %TEMP%\apiprobe\<id>, created empty. Returns 0 on failure (r is set). */
int probe_tmpdir(result_t *r, const char *id, wchar_t *out, size_t cch);
/* Recursively deletes a directory created by probe_tmpdir. */
void rm_tree(const wchar_t *dir);
/* Waits for a process, returns its exit code or (DWORD)-1 on timeout. */
DWORD wait_exit(HANDLE process, DWORD ms);
/* Full path of apiprobe.exe. */
void self_path(wchar_t *out, size_t cch);
/* %SystemRoot%\System32\<name>. */
void sys32_path(const wchar_t *name, wchar_t *out, size_t cch);
/* Starts "apiprobe.exe --sleep <ms>"; flags go to CreateProcessW. */
int start_sleeper(DWORD ms, DWORD flags, PROCESS_INFORMATION *pi);
/* Current OS version from ntdll!RtlGetVersion (always present). */
void os_version(DWORD *major, DWORD *minor, DWORD *build);

/* Probe tables, one per probes_<family>.c, terminated by PROBE_END. */
extern const probe_t probes_kernel32[];
extern const probe_t probes_advapi32[];
extern const probe_t probes_crypto[];
extern const probe_t probes_user32[];
extern const probe_t probes_gdi32[];
extern const probe_t probes_shell[];
extern const probe_t probes_com[];
extern const probe_t probes_net[];
extern const probe_t probes_diag[];
extern const probe_t probes_accounts[];
extern const probe_t probes_crt[];
extern const probe_t probes_loadonly[];

#define IDS_APIPROBE_HELLO 101

#endif
