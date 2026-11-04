/* apiprobe.c - Win32 API availability runner for nanoserver and friends.
 *
 * L1: LoadLibraryExW of every DLL in data/dlls.txt
 * L2: GetProcAddress of every export in data/exports/<dll>.txt
 * L3: hand-written behaviour probes (probes_*.c)
 *
 * Every probe runs in a child process (apiprobe.exe --child ...) with a
 * timeout; L1/L2 run in batches of 50 DLLs per child. Results are compared
 * with a baseline file and written as JUnit XML, JSON Lines and TAP.
 *
 * Only kernel32.dll and msvcrt.dll may be imported (checked in CI).
 */
#define __USE_MINGW_ANSI_STDIO 1
#include "probes.h"
#include <stdlib.h>
#include <stdarg.h>
#include <fcntl.h>
#include <io.h>

int g_network = 0;

static const char *const STATUS_NAMES[ST_COUNT] = {
    "ok", "skip", "error", "missing-export", "missing-dll", "timeout", "crash"
};

static int status_from_name(const char *s)
{
    for (int i = 0; i < ST_COUNT; i++)
        if (strcmp(s, STATUS_NAMES[i]) == 0) return i;
    return -1;
}

/* ------------------------------------------------------------------------ */
/* small utilities                                                          */

static void *xmalloc(size_t n)
{
    void *p = malloc(n ? n : 1);
    if (!p) { fputs("apiprobe: out of memory\n", stderr); ExitProcess(3); }
    return p;
}

static void *xrealloc(void *p, size_t n)
{
    p = realloc(p, n ? n : 1);
    if (!p) { fputs("apiprobe: out of memory\n", stderr); ExitProcess(3); }
    return p;
}

static char *xstrdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *d = xmalloc(n);
    memcpy(d, s, n);
    return d;
}

static char *w2u(const wchar_t *w)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *s = xmalloc(n > 0 ? (size_t)n : 1);
    if (n <= 0) { s[0] = 0; return s; }
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}

static wchar_t *u2w(const char *s)
{
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    wchar_t *w = xmalloc(sizeof(wchar_t) * (n > 0 ? (size_t)n : 1));
    if (n <= 0) { w[0] = 0; return w; }
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

typedef struct { char *buf; size_t len, cap; } sbuf_t;

static void sb_putn(sbuf_t *b, const char *s, size_t n)
{
    if (b->len + n + 1 > b->cap) {
        b->cap = (b->len + n + 1) * 2;
        b->buf = xrealloc(b->buf, b->cap);
    }
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = 0;
}

static void sb_puts(sbuf_t *b, const char *s) { sb_putn(b, s, strlen(s)); }

static void sb_printf(sbuf_t *b, const char *fmt, ...)
{
    char tmp[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n >= sizeof tmp) n = sizeof tmp - 1;
    sb_putn(b, tmp, (size_t)n);
}

/* Case-insensitive glob with * and ?; pattern may be a comma separated list. */
static int glob_one(const char *p, const char *s)
{
    while (*p && *p != ',') {
        if (*p == '*') {
            p++;
            if (!*p || *p == ',') return 1;
            for (; *s; s++)
                if (glob_one(p, s)) return 1;
            return 0;
        }
        if (!*s) return 0;
        if (*p != '?' && tolower((unsigned char)*p) != tolower((unsigned char)*s)) return 0;
        p++;
        s++;
    }
    return *s == 0;
}

static int glob_match(const char *pattern, const char *s)
{
    if (!pattern || !*pattern) return 1;
    const char *p = pattern;
    for (;;) {
        if (glob_one(p, s)) return 1;
        p = strchr(p, ',');
        if (!p) return 0;
        p++;
    }
}

/* String -> int map (open addressing, grows). */
typedef struct { char **keys; int *vals; size_t cap, n; } smap_t;

static size_t hash_str(const char *s)
{
    size_t h = 1469598103934665603ull;
    for (; *s; s++) h = (h ^ (unsigned char)*s) * 1099511628211ull;
    return h;
}

static void smap_put(smap_t *m, const char *key, int val);

static void smap_grow(smap_t *m)
{
    smap_t n = { 0 };
    n.cap = m->cap ? m->cap * 2 : 1024;
    n.keys = calloc(n.cap, sizeof(char *));
    n.vals = calloc(n.cap, sizeof(int));
    if (!n.keys || !n.vals) { fputs("apiprobe: out of memory\n", stderr); ExitProcess(3); }
    for (size_t i = 0; i < m->cap; i++)
        if (m->keys[i]) {
            smap_put(&n, m->keys[i], m->vals[i]);
            free(m->keys[i]);
        }
    free(m->keys);
    free(m->vals);
    *m = n;
}

static int *smap_find(const smap_t *m, const char *key)
{
    if (!m->cap) return NULL;
    size_t i = hash_str(key) & (m->cap - 1);
    while (m->keys[i]) {
        if (strcmp(m->keys[i], key) == 0) return &m->vals[i];
        i = (i + 1) & (m->cap - 1);
    }
    return NULL;
}

static void smap_put(smap_t *m, const char *key, int val)
{
    int *v = smap_find(m, key);
    if (v) { *v = val; return; }
    if ((m->n + 1) * 2 > m->cap) smap_grow(m);
    size_t i = hash_str(key) & (m->cap - 1);
    while (m->keys[i]) i = (i + 1) & (m->cap - 1);
    m->keys[i] = xstrdup(key);
    m->vals[i] = val;
    m->n++;
}

static void mkdirs_for(const wchar_t *file)
{
    wchar_t tmp[MAX_PATH * 2];
    wcsncpy(tmp, file, MAX_PATH * 2 - 1);
    tmp[MAX_PATH * 2 - 1] = 0;
    for (wchar_t *p = tmp + 3; *p; p++) {
        if (*p == L'\\' || *p == L'/') {
            wchar_t c = *p;
            *p = 0;
            CreateDirectoryW(tmp, NULL);
            *p = c;
        }
    }
}

static FILE *open_out(const char *path)
{
    wchar_t *w = u2w(path);
    mkdirs_for(w);
    FILE *f = _wfopen(w, L"wb");
    free(w);
    if (!f) fprintf(stderr, "apiprobe: cannot write %s\n", path);
    return f;
}

static double now_ms(void)
{
    static LARGE_INTEGER freq;
    LARGE_INTEGER c;
    if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)freq.QuadPart;
}

static void sanitize(char *s)
{
    for (; *s; s++)
        if (*s == '\t' || *s == '\r' || *s == '\n') *s = ' ';
}

/* ------------------------------------------------------------------------ */
/* helpers used by probes                                                   */

void *need_(result_t *r, const char *dll, const char *name)
{
    wchar_t w[MAX_PATH];
    int n = MultiByteToWideChar(CP_UTF8, 0, dll, -1, w, MAX_PATH - 8);
    if (n <= 0) w[0] = 0;
    if (!wcschr(w, L'.')) wcscat(w, L".dll");
    HMODULE h = LoadLibraryExW(w, NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!h) {
        r->status = ST_MISSING_DLL;
        r->win32_error = GetLastError();
        snprintf(r->detail, sizeof r->detail, "%s did not load", dll);
        return NULL;
    }
    FARPROC p = GetProcAddress(h, name);
    if (!p) {
        r->status = ST_MISSING_EXPORT;
        r->win32_error = GetLastError();
        snprintf(r->detail, sizeof r->detail, "%s!%s not found", dll, name);
        return NULL;
    }
    return (void *)p;
}

static void vset(result_t *r, status_t st, DWORD err, const char *fmt, va_list ap)
{
    r->status = st;
    r->win32_error = err;
    if (fmt) vsnprintf(r->detail, sizeof r->detail, fmt, ap);
    else r->detail[0] = 0;
}

void ok(result_t *r, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vset(r, ST_OK, 0, fmt, ap);
    va_end(ap);
}

void fail(result_t *r, const char *fmt, ...)
{
    DWORD e = GetLastError();
    va_list ap;
    va_start(ap, fmt);
    vset(r, ST_ERROR, e, fmt, ap);
    va_end(ap);
}

void fail_code(result_t *r, DWORD code, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vset(r, ST_ERROR, code, fmt, ap);
    va_end(ap);
}

void skip(result_t *r, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vset(r, ST_SKIP, 0, fmt, ap);
    va_end(ap);
}

void rm_tree(const wchar_t *dir)
{
    wchar_t pat[MAX_PATH * 2];
    WIN32_FIND_DATAW fd;
    _snwprintf(pat, MAX_PATH * 2, L"%ls\\*", dir);
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
            wchar_t p[MAX_PATH * 2];
            _snwprintf(p, MAX_PATH * 2, L"%ls\\%ls", dir, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) RemoveDirectoryW(p);
                else rm_tree(p);
            } else {
                SetFileAttributesW(p, FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(p);
            }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryW(dir);
}

int probe_tmpdir(result_t *r, const char *id, wchar_t *out, size_t cch)
{
    wchar_t tmp[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, tmp);
    if (!n || n >= MAX_PATH) { fail(r, "GetTempPathW failed"); return 0; }
    wchar_t *wid = u2w(id);
    _snwprintf(out, cch, L"%lsapiprobe", tmp);
    CreateDirectoryW(out, NULL);
    _snwprintf(out, cch, L"%lsapiprobe\\%ls", tmp, wid);
    free(wid);
    rm_tree(out);
    if (!CreateDirectoryW(out, NULL)) { fail(r, "cannot create temp dir"); return 0; }
    return 1;
}

void self_path(wchar_t *out, size_t cch)
{
    DWORD n = GetModuleFileNameW(NULL, out, (DWORD)cch);
    if (!n || n >= cch) out[0] = 0;
}

void sys32_path(const wchar_t *name, wchar_t *out, size_t cch)
{
    wchar_t sys[MAX_PATH];
    UINT n = GetSystemDirectoryW(sys, MAX_PATH);
    if (!n || n >= MAX_PATH) wcscpy(sys, L"C:\\Windows\\System32");
    _snwprintf(out, cch, L"%ls\\%ls", sys, name);
    out[cch - 1] = 0;
}

int start_sleeper(DWORD ms, DWORD flags, PROCESS_INFORMATION *pi)
{
    wchar_t exe[MAX_PATH * 2], cmd[MAX_PATH * 2 + 64];
    self_path(exe, MAX_PATH * 2);
    _snwprintf(cmd, MAX_PATH * 2 + 64, L"\"%ls\" --sleep %lu", exe, (unsigned long)ms);
    STARTUPINFOW si;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    memset(pi, 0, sizeof *pi);
    return CreateProcessW(exe, cmd, NULL, NULL, FALSE, flags | CREATE_NO_WINDOW, NULL, NULL, &si, pi) != 0;
}

/* Exported so dbghelp can find a symbol in the stripped executable. */
__declspec(dllexport) int apiprobe_marker(int x)
{
    return x * 2 + 1;
}

DWORD wait_exit(HANDLE process, DWORD ms)
{
    DWORD code = (DWORD)-1;
    if (WaitForSingleObject(process, ms) != WAIT_OBJECT_0) return (DWORD)-1;
    GetExitCodeProcess(process, &code);
    return code;
}

void os_version(DWORD *major, DWORD *minor, DWORD *build)
{
    typedef LONG (WINAPI *rtlgv_t)(OSVERSIONINFOW *);
    OSVERSIONINFOW vi;
    memset(&vi, 0, sizeof vi);
    vi.dwOSVersionInfoSize = sizeof vi;
    rtlgv_t f = (rtlgv_t)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
    if (f) f(&vi);
    *major = vi.dwMajorVersion;
    *minor = vi.dwMinorVersion;
    *build = vi.dwBuildNumber;
}

static void os_build_string(char *out, size_t n)
{
    DWORD ma, mi, bu, ubr = 0, cb = sizeof ubr;
    typedef LONG (WINAPI *rgv_t)(HKEY, LPCWSTR, LPCWSTR, DWORD, LPDWORD, PVOID, LPDWORD);
    os_version(&ma, &mi, &bu);
    HMODULE adv = LoadLibraryExW(L"advapi32.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    rgv_t f = adv ? (rgv_t)(void *)GetProcAddress(adv, "RegGetValueW") : NULL;
    if (f && f(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", L"UBR",
               0x00000010 /* RRF_RT_REG_DWORD */, NULL, &ubr, &cb) == 0)
        snprintf(out, n, "%lu.%lu", (unsigned long)bu, (unsigned long)ubr);
    else
        snprintf(out, n, "%lu", (unsigned long)bu);
}

/* ------------------------------------------------------------------------ */
/* probe registry                                                           */

static const probe_t *const TABLES[] = {
    probes_kernel32, probes_advapi32, probes_crypto, probes_user32, probes_gdi32,
    probes_shell, probes_com, probes_net, probes_diag, probes_accounts, probes_crt,
    probes_loadonly, NULL
};

static const probe_t *find_probe(const char *id)
{
    for (int t = 0; TABLES[t]; t++)
        for (const probe_t *p = TABLES[t]; p->id; p++)
            if (_stricmp(p->id, id) == 0) return p;
    return NULL;
}

/* ------------------------------------------------------------------------ */
/* child modes                                                              */

static LONG WINAPI crash_filter(EXCEPTION_POINTERS *ep)
{
    fflush(stdout);
    TerminateProcess(GetCurrentProcess(), ep->ExceptionRecord->ExceptionCode);
    return EXCEPTION_EXECUTE_HANDLER;
}

static void child_setup(void)
{
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    SetUnhandledExceptionFilter(crash_filter);
    _setmode(_fileno(stdout), _O_BINARY);
}

static int child_l3(const char *id)
{
    const probe_t *p = find_probe(id);
    if (!p) {
        printf("R\terror\t0\t0\tunknown probe %s\n", id);
        return 2;
    }
    result_t r;
    memset(&r, 0, sizeof r);
    double t0 = now_ms();
    if (p->needs_network && !g_network) {
        skip(&r, "needs --network");
    } else if (p->fn) {
        r.status = ST_OK;
        p->fn(&r);
    } else if (!p->function[0]) {
        /* load-only probe */
        wchar_t w[MAX_PATH];
        _snwprintf(w, MAX_PATH, L"%hs.dll", p->dll);
        w[MAX_PATH - 1] = 0;
        if (LoadLibraryExW(w, NULL, LOAD_LIBRARY_SEARCH_SYSTEM32)) ok(&r, "%s loaded", p->dll);
        else {
            r.status = ST_MISSING_DLL;
            r.win32_error = GetLastError();
            snprintf(r.detail, sizeof r.detail, "%s did not load", p->dll);
        }
    } else {
        /* load-and-resolve probe */
        if (need_(&r, p->dll, p->function)) ok(&r, "%s!%s resolved", p->dll, p->function);
    }
    double ms = now_ms() - t0;
    sanitize(r.detail);
    printf("R\t%s\t%lu\t%.3f\t%s\n", STATUS_NAMES[r.status], (unsigned long)r.win32_error, ms, r.detail);
    fflush(stdout);
    return 0;
}

static int child_dlls(int l2, const wchar_t *data_dir, int n, wchar_t **names)
{
    char line[1024];
    for (int i = 0; i < n; i++) {
        char *name = w2u(names[i]);
        wchar_t file[MAX_PATH];
        _snwprintf(file, MAX_PATH, L"%ls.dll", names[i]);
        double t0 = now_ms();
        SetLastError(0);
        HMODULE h = LoadLibraryExW(file, NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
        DWORD err = h ? 0 : GetLastError();
        printf("L1\t%s\t%s\t%lu\t%.3f\n", name, h ? "ok" : "missing-dll", (unsigned long)err, now_ms() - t0);
        fflush(stdout);
        if (h && l2) {
            wchar_t ef[MAX_PATH * 2];
            _snwprintf(ef, MAX_PATH * 2, L"%ls\\exports\\%ls.txt", data_dir, names[i]);
            FILE *f = _wfopen(ef, L"rb");
            int total = 0, missing = 0;
            t0 = now_ms();
            if (f) {
                while (fgets(line, sizeof line, f)) {
                    line[strcspn(line, "\r\n")] = 0;
                    if (!line[0]) continue;
                    total++;
                    SetLastError(0);
                    if (!GetProcAddress(h, line)) {
                        missing++;
                        printf("X\t%s\t%s\t%lu\n", name, line, (unsigned long)GetLastError());
                    }
                }
                fclose(f);
            }
            printf("L2\t%s\t%d\t%d\t%.3f\n", name, total, total - missing, now_ms() - t0);
        }
        printf("D\t%s\n", name);
        fflush(stdout);
        free(name);
    }
    return 0;
}

/* ------------------------------------------------------------------------ */
/* parent: run a child                                                      */

typedef struct {
    char *out;
    size_t len;
    DWORD exit_code;
    int timed_out;
    int started;
    double ms;
} child_run_t;

static void drain(HANDLE rd, sbuf_t *b, int *eof)
{
    char buf[8192];
    DWORD avail = 0, got = 0;
    for (;;) {
        if (!PeekNamedPipe(rd, NULL, 0, NULL, &avail, NULL)) { *eof = 1; return; }
        if (!avail) return;
        if (!ReadFile(rd, buf, avail < sizeof buf ? avail : sizeof buf, &got, NULL) || !got) { *eof = 1; return; }
        sb_putn(b, buf, got);
    }
}

static void run_child(const wchar_t *args, DWORD timeout_ms, child_run_t *cr)
{
    memset(cr, 0, sizeof *cr);
    wchar_t exe[MAX_PATH * 2];
    GetModuleFileNameW(NULL, exe, MAX_PATH * 2);
    size_t cl = wcslen(exe) + wcslen(args) + 8;
    wchar_t *cmd = xmalloc(cl * sizeof(wchar_t));
    _snwprintf(cmd, cl, L"\"%ls\" %ls", exe, args);

    SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
    HANDLE rd = NULL, wr = NULL;
    CreatePipe(&rd, &wr, &sa, 1 << 16);
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si);
    memset(&pi, 0, sizeof pi);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    si.hStdOutput = wr;
    si.hStdError = wr;

    sbuf_t out = { 0 };
    double t0 = now_ms();
    BOOL started = CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi);
    CloseHandle(wr);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    free(cmd);
    if (!started) {
        cr->exit_code = GetLastError();
        CloseHandle(rd);
        sb_printf(&out, "CreateProcessW failed: %lu", (unsigned long)cr->exit_code);
        cr->out = out.buf;
        cr->len = out.len;
        return;
    }
    cr->started = 1;
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION li;
        memset(&li, 0, sizeof li);
        li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &li, sizeof li);
        AssignProcessToJobObject(job, pi.hProcess);
    }
    ResumeThread(pi.hThread);

    int eof = 0;
    for (;;) {
        drain(rd, &out, &eof);
        if (WaitForSingleObject(pi.hProcess, 5) == WAIT_OBJECT_0) break;
        if (now_ms() - t0 > timeout_ms) {
            cr->timed_out = 1;
            if (job) TerminateJobObject(job, 0xDEAD);
            TerminateProcess(pi.hProcess, 0xDEAD);
            WaitForSingleObject(pi.hProcess, 5000);
            break;
        }
    }
    cr->ms = now_ms() - t0;
    GetExitCodeProcess(pi.hProcess, &cr->exit_code);
    if (job) TerminateJobObject(job, 0); /* stragglers keep the pipe open */
    double t1 = now_ms();
    while (!eof && now_ms() - t1 < 2000) {
        size_t before = out.len;
        drain(rd, &out, &eof);
        if (!eof && out.len == before) Sleep(5);
    }
    if (job) CloseHandle(job);
    CloseHandle(rd);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (!out.buf) sb_puts(&out, "");
    cr->out = out.buf;
    cr->len = out.len;
}

/* ------------------------------------------------------------------------ */
/* records, baseline, verdicts                                              */

enum { V_PASS, V_SKIP, V_FAIL, V_IMPROVED };

typedef struct {
    int level;           /* 1, 2, 3 */
    int is_export;       /* level 2: one missing export */
    char *dll;
    char *function;      /* L2 export name, L3 function, NULL otherwise */
    const char *check;
    char *probe_id;      /* L3 id */
    status_t status;
    DWORD err;
    double ms;
    char *detail;
    int total, resolved; /* L2 summary */
    int first_export, n_export;
    status_t baseline;
    int verdict;
    char *improved;      /* L2 summary: exports that improved */
    int n_improved;
} rec_t;

static rec_t *g_recs;
static size_t g_nrec, g_caprec;

static struct {
    int levels;              /* bit mask 1<<1 | 1<<2 | 1<<3 */
    const char *filter;
    wchar_t *data_dir;
    DWORD timeout_ms;
    const char *junit, *jsonl, *target, *winver, *baseline, *write_baseline;
} opt;

static char g_os_build[64];
static smap_t g_base;        /* key -> status */
static smap_t g_base_seen;   /* key -> 1 */
static smap_t g_l2_summary;  /* dll -> record index (evaluated L2) */
static int g_tap_n, g_fail, g_skip, g_improved, g_warn_printed;

static rec_t *new_rec(void)
{
    if (g_nrec == g_caprec) {
        g_caprec = g_caprec ? g_caprec * 2 : 4096;
        g_recs = xrealloc(g_recs, g_caprec * sizeof(rec_t));
    }
    rec_t *r = &g_recs[g_nrec++];
    memset(r, 0, sizeof *r);
    return r;
}

static void rec_key(const rec_t *r, char *key, size_t n)
{
    if (r->level == 1) snprintf(key, n, "L1 %s", r->dll);
    else if (r->level == 2 && r->is_export) snprintf(key, n, "L2 %s!%s", r->dll, r->function);
    else if (r->level == 2) snprintf(key, n, "L2 %s", r->dll);
    else snprintf(key, n, "L3 %s", r->probe_id);
}

static status_t base_lookup(const char *key)
{
    int *v = smap_find(&g_base, key);
    if (v) smap_put(&g_base_seen, key, 1);
    return v ? (status_t)*v : ST_OK;
}

static int verdict_for(status_t st, status_t base)
{
    if (st == base) return st == ST_OK ? V_PASS : V_SKIP;
    /* A skipped probe (no --network) is never a regression. */
    if (st == ST_SKIP && base == ST_OK) return V_SKIP;
    return st > base ? V_FAIL : V_IMPROVED;
}

static void warn_improved(const char *key, status_t was, status_t now)
{
    g_improved++;
    if (g_warn_printed < 50) {
        printf("::warning title=apiprobe improvement::%s improved: was %s, now %s - update the baseline\n",
               key, STATUS_NAMES[was], STATUS_NAMES[now]);
        g_warn_printed++;
    } else if (g_warn_printed == 50) {
        printf("::warning title=apiprobe improvement::more improvements, see results.jsonl\n");
        g_warn_printed++;
    }
}

static void tap_line(const rec_t *r)
{
    char key[600];
    rec_key(r, key, sizeof key);
    g_tap_n++;
    if (r->level == 2) {
        snprintf(key + strlen(key), sizeof key - strlen(key), " (%d/%d exports)", r->resolved, r->total);
    }
    switch (r->verdict) {
    case V_PASS:
        printf("ok %d - %s # baseline ok\n", g_tap_n, key);
        break;
    case V_SKIP:
        printf("ok %d - %s # SKIP %s (win32 %lu), expected by baseline\n", g_tap_n, key,
               STATUS_NAMES[r->status], (unsigned long)r->err);
        break;
    case V_IMPROVED:
        printf("ok %d - %s # improved: was %s, now %s\n", g_tap_n, key,
               STATUS_NAMES[r->baseline], STATUS_NAMES[r->status]);
        break;
    default:
        printf("not ok %d - %s # %s %lu (baseline %s)%s%s\n", g_tap_n, key, STATUS_NAMES[r->status],
               (unsigned long)r->err, STATUS_NAMES[r->baseline], r->detail && *r->detail ? ": " : "",
               r->detail ? r->detail : "");
        break;
    }
    fflush(stdout);
}

static void count_verdict(rec_t *r)
{
    char key[600];
    if (r->verdict == V_FAIL) g_fail++;
    else if (r->verdict == V_SKIP) g_skip++;
    else if (r->verdict == V_IMPROVED) {
        rec_key(r, key, sizeof key);
        warn_improved(key, r->baseline, r->status);
    }
}

static int load_baseline(const char *path)
{
    wchar_t *w = u2w(path);
    FILE *f = _wfopen(w, L"rb");
    free(w);
    if (!f) return 0;
    char line[1024];
    int n = 0;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0] || line[0] == '#') continue;
        char *eq = strstr(line, " = ");
        if (!eq) continue;
        *eq = 0;
        int st = status_from_name(eq + 3);
        if (st < 0) {
            fprintf(stderr, "apiprobe: baseline: unknown status '%s' for %s\n", eq + 3, line);
            continue;
        }
        smap_put(&g_base, line, st);
        n++;
    }
    fclose(f);
    return n;
}

/* ------------------------------------------------------------------------ */
/* parent: L1/L2                                                            */

typedef struct {
    char *name;
    int done;
    int l1_seen;
    status_t l1;
    DWORD l1_err;
    double l1_ms;
    int l2_seen;
    int total, resolved;
    double l2_ms;
    char **missing;
    DWORD *missing_err;
    int n_missing;
} dllres_t;

static void dllres_free(dllres_t *d)
{
    for (int i = 0; i < d->n_missing; i++) free(d->missing[i]);
    free(d->missing);
    free(d->missing_err);
    memset(d, 0, sizeof *d);
}

static void commit_dll(dllres_t *d, int want_l2, const char *crash_detail, status_t crash_st)
{
    char key[600];
    rec_t *r1 = new_rec();
    size_t i1 = g_nrec - 1;
    r1->level = 1;
    r1->dll = xstrdup(d->name);
    if (d->l1_seen) {
        r1->status = d->l1;
        r1->err = d->l1_err;
        r1->ms = d->l1_ms;
    } else {
        r1->status = crash_st;
        r1->err = 0;
        r1->detail = xstrdup(crash_detail ? crash_detail : "");
    }
    rec_key(r1, key, sizeof key);
    r1->baseline = base_lookup(key);
    r1->verdict = verdict_for(r1->status, r1->baseline);
    count_verdict(r1);
    tap_line(r1);
    if (!want_l2) return;

    snprintf(key, sizeof key, "L1 %s", d->name);
    status_t l1_base = g_recs[i1].baseline;
    status_t l1_now = g_recs[i1].status;
    int first = (int)g_nrec;
    int any_fail = 0, any_missing = 0;
    if (l1_now == ST_OK && d->l2_seen) {
        for (int i = 0; i < d->n_missing; i++) {
            rec_t *x = new_rec();
            x->level = 2;
            x->is_export = 1;
            x->dll = xstrdup(d->name);
            x->function = d->missing[i];
            d->missing[i] = NULL;
            x->status = ST_MISSING_EXPORT;
            x->err = d->missing_err[i];
            rec_key(x, key, sizeof key);
            x->baseline = base_lookup(key);
            if (l1_base != ST_OK) {
                x->verdict = V_SKIP; /* DLL newly loads: exports are informational */
            } else {
                x->verdict = verdict_for(x->status, x->baseline);
                if (x->verdict == V_IMPROVED) count_verdict(x);
            }
            if (x->verdict == V_FAIL) any_fail = 1;
            any_missing = 1;
        }
    }
    rec_t *s = new_rec();
    s->level = 2;
    s->dll = xstrdup(d->name);
    s->first_export = first;
    s->n_export = (int)g_nrec - 1 - first;
    if (l1_now != ST_OK) {
        s->status = l1_now;
        s->baseline = l1_now;
        s->verdict = V_SKIP;
        s->detail = xstrdup("not evaluated: the DLL did not load");
        s->total = s->resolved = 0;
    } else if (!d->l2_seen) {
        s->status = crash_st;
        s->baseline = ST_OK;
        s->verdict = V_FAIL;
        s->detail = xstrdup(crash_detail ? crash_detail : "export scan did not finish");
    } else {
        s->total = d->total;
        s->resolved = d->resolved;
        s->ms = d->l2_ms;
        s->status = any_missing ? ST_MISSING_EXPORT : ST_OK;
        s->baseline = s->status;
        s->verdict = any_fail ? V_FAIL : any_missing ? V_SKIP : V_PASS;
        if (any_fail) s->baseline = ST_OK;
        smap_put(&g_l2_summary, d->name, (int)(g_nrec - 1));
    }
    if (s->verdict == V_FAIL) g_fail++;
    else if (s->verdict == V_SKIP) g_skip++;
    tap_line(s);
}

static dllres_t *find_dllres(dllres_t *v, int n, const char *name)
{
    for (int i = 0; i < n; i++)
        if (strcmp(v[i].name, name) == 0) return &v[i];
    return NULL;
}

static void parse_dll_output(char *out, dllres_t *v, int n)
{
    char *save = NULL;
    for (char *line = strtok_r(out, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        line[strcspn(line, "\r")] = 0;
        char *f[6] = { 0 };
        int nf = 0;
        char *p = line;
        while (nf < 6) {
            f[nf++] = p;
            p = strchr(p, '\t');
            if (!p) break;
            *p++ = 0;
        }
        if (nf < 2) continue;
        dllres_t *d = find_dllres(v, n, f[1]);
        if (!d) continue;
        if (!strcmp(f[0], "L1") && nf >= 5) {
            d->l1_seen = 1;
            int st = status_from_name(f[2]);
            d->l1 = st < 0 ? ST_ERROR : (status_t)st;
            d->l1_err = strtoul(f[3], NULL, 10);
            d->l1_ms = atof(f[4]);
        } else if (!strcmp(f[0], "X") && nf >= 4) {
            d->missing = xrealloc(d->missing, (d->n_missing + 1) * sizeof(char *));
            d->missing_err = xrealloc(d->missing_err, (d->n_missing + 1) * sizeof(DWORD));
            d->missing[d->n_missing] = xstrdup(f[2]);
            d->missing_err[d->n_missing] = strtoul(f[3], NULL, 10);
            d->n_missing++;
        } else if (!strcmp(f[0], "L2") && nf >= 5) {
            d->l2_seen = 1;
            d->total = atoi(f[2]);
            d->resolved = atoi(f[3]);
            d->l2_ms = atof(f[4]);
        } else if (!strcmp(f[0], "D")) {
            d->done = 1;
        }
    }
}

static void tail_detail(const child_run_t *cr, char *out, size_t n)
{
    const char *t = cr->out ? cr->out : "";
    size_t len = cr->len;
    if (len > 200) t += len - 200;
    if (cr->timed_out) snprintf(out, n, "timed out after %.0f ms", cr->ms);
    else snprintf(out, n, "child exit 0x%08lX; output tail: %s", (unsigned long)cr->exit_code, t);
    sanitize(out);
}

static void run_dll_batch(char **names, int n, int want_l2)
{
    sbuf_t args = { 0 };
    char *dd = w2u(opt.data_dir);
    sb_printf(&args, "--child-dlls %d \"%s\"", want_l2, dd);
    free(dd);
    for (int i = 0; i < n; i++) sb_printf(&args, " %s", names[i]);
    wchar_t *wargs = u2w(args.buf);
    free(args.buf);
    child_run_t cr;
    run_child(wargs, opt.timeout_ms * (n > 1 ? 3 : 1), &cr);
    free(wargs);

    dllres_t *v = calloc((size_t)n, sizeof(dllres_t));
    for (int i = 0; i < n; i++) v[i].name = names[i];
    char *copy = xstrdup(cr.out);
    parse_dll_output(copy, v, n);
    free(copy);

    int clean = cr.started && !cr.timed_out && cr.exit_code == 0;
    char detail[400];
    tail_detail(&cr, detail, sizeof detail);
    status_t bad = cr.timed_out ? ST_TIMEOUT : ST_CRASH;

    char **redo = xmalloc(sizeof(char *) * (size_t)n);
    int nredo = 0;
    for (int i = 0; i < n; i++) {
        if (v[i].done) commit_dll(&v[i], want_l2, NULL, ST_CRASH);
        else if (clean) commit_dll(&v[i], want_l2, "no result from child", ST_CRASH);
        else if (n > 1) redo[nredo++] = names[i];
        else commit_dll(&v[i], want_l2, detail, bad);
        char *keep = v[i].name;
        dllres_free(&v[i]);
        v[i].name = keep;
    }
    free(v);
    free(cr.out);
    if (nredo) {
        printf("# batch child failed (%s); re-running %d DLL(s) one by one\n", detail, nredo);
        for (int i = 0; i < nredo; i++) run_dll_batch(&redo[i], 1, want_l2);
    }
    free(redo);
}

static void run_l1_l2(void)
{
    wchar_t path[MAX_PATH * 2];
    _snwprintf(path, MAX_PATH * 2, L"%ls\\dlls.txt", opt.data_dir);
    FILE *f = _wfopen(path, L"rb");
    if (!f) {
        char *p = w2u(path);
        printf("# no inventory at %s, skipping L1 and L2\n", p);
        free(p);
        return;
    }
    char line[512];
    char **names = NULL;
    int n = 0;
    int want_l2 = (opt.levels & (1 << 2)) != 0;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0] || line[0] == '#') continue;
        char k1[600], k2[600];
        snprintf(k1, sizeof k1, "L1 %s", line);
        snprintf(k2, sizeof k2, "L2 %s", line);
        if (!glob_match(opt.filter, k1) && !glob_match(opt.filter, k2)) continue;
        names = xrealloc(names, sizeof(char *) * (size_t)(n + 1));
        names[n++] = xstrdup(line);
    }
    fclose(f);
    for (int i = 0; i < n; i += 50) run_dll_batch(&names[i], n - i < 50 ? n - i : 50, want_l2);
    for (int i = 0; i < n; i++) free(names[i]);
    free(names);
}

/* ------------------------------------------------------------------------ */
/* parent: L3                                                               */

static void run_l3(void)
{
    char key[600];
    for (int t = 0; TABLES[t]; t++) {
        for (const probe_t *p = TABLES[t]; p->id; p++) {
            snprintf(key, sizeof key, "L3 %s", p->id);
            if (!glob_match(opt.filter, key)) continue;
            wchar_t args[512];
            wchar_t *wid = u2w(p->id);
            _snwprintf(args, 512, L"--child %ls%ls", wid, g_network ? L" --network" : L"");
            free(wid);
            child_run_t cr;
            run_child(args, opt.timeout_ms, &cr);

            rec_t *r = new_rec();
            r->level = 3;
            r->dll = xstrdup(p->dll);
            r->function = xstrdup(p->function);
            r->check = p->check;
            r->probe_id = xstrdup(p->id);
            char *line = strstr(cr.out, "R\t");
            while (line && line != cr.out && line[-1] != '\n') line = strstr(line + 1, "R\t");
            if (line && !cr.timed_out) {
                char *f[5] = { 0 };
                int nf = 0;
                char *q = line;
                char *nl = strchr(q, '\n');
                if (nl) *nl = 0;
                q[strcspn(q, "\r")] = 0;
                while (nf < 5) {
                    f[nf++] = q;
                    if (nf == 5) break;
                    q = strchr(q, '\t');
                    if (!q) break;
                    *q++ = 0;
                }
                int st = nf >= 2 ? status_from_name(f[1]) : -1;
                r->status = st < 0 ? ST_ERROR : (status_t)st;
                r->err = nf >= 3 ? strtoul(f[2], NULL, 10) : 0;
                r->ms = nf >= 4 ? atof(f[3]) : cr.ms;
                r->detail = xstrdup(nf >= 5 ? f[4] : "");
            } else {
                char d[400];
                tail_detail(&cr, d, sizeof d);
                r->status = cr.timed_out ? ST_TIMEOUT : ST_CRASH;
                r->err = cr.timed_out ? 0 : cr.exit_code;
                r->ms = cr.ms;
                r->detail = xstrdup(d);
            }
            free(cr.out);
            rec_key(r, key, sizeof key);
            r->baseline = base_lookup(key);
            r->verdict = verdict_for(r->status, r->baseline);
            count_verdict(r);
            tap_line(r);
        }
    }
}

/* L2 exports listed in the baseline that now resolve. */
static void find_l2_improvements(void)
{
    for (size_t i = 0; i < g_base.cap; i++) {
        const char *k = g_base.keys[i];
        if (!k || strncmp(k, "L2 ", 3) != 0) continue;
        if (smap_find(&g_base_seen, k)) continue;
        const char *bang = strchr(k + 3, '!');
        if (!bang) continue;
        char dll[300];
        size_t n = (size_t)(bang - (k + 3));
        if (n >= sizeof dll) continue;
        memcpy(dll, k + 3, n);
        dll[n] = 0;
        int *idx = smap_find(&g_l2_summary, dll);
        if (!idx) continue;
        rec_t *s = &g_recs[*idx];
        snprintf(dll, sizeof dll, "L1 %s", s->dll);
        int *l1b = smap_find(&g_base, dll);
        if (l1b && *l1b != ST_OK) continue;
        sbuf_t b = { 0 };
        if (s->improved) sb_puts(&b, s->improved), sb_puts(&b, " ");
        if (s->n_improved < 100) sb_puts(&b, bang + 1);
        else if (s->n_improved == 100) sb_puts(&b, "...");
        free(s->improved);
        s->improved = b.buf;
        s->n_improved++;
        if (s->verdict == V_PASS || s->verdict == V_SKIP) {
            if (s->verdict == V_SKIP) g_skip--;
            s->verdict = V_IMPROVED;
        }
        warn_improved(k, (status_t)g_base.vals[i], ST_OK);
    }
}

/* ------------------------------------------------------------------------ */
/* writers                                                                  */

static void xml_esc(FILE *f, const char *s)
{
    for (; s && *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
        case '&': fputs("&amp;", f); break;
        case '<': fputs("&lt;", f); break;
        case '>': fputs("&gt;", f); break;
        case '"': fputs("&quot;", f); break;
        case '\'': fputs("&apos;", f); break;
        default:
            if (c < 0x20 && c != '\t' && c != '\n') fputc(' ', f);
            else fputc(c, f);
        }
    }
}

static void json_esc(FILE *f, const char *s)
{
    fputc('"', f);
    for (; s && *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { fputc('\\', f); fputc(c, f); }
        else if (c < 0x20) fprintf(f, "\\u%04x", c);
        else fputc(c, f);
    }
    fputc('"', f);
}

static const char *case_name(const rec_t *r, char *buf, size_t n)
{
    if (r->level == 1) return "load";
    if (r->level == 2) return "exports";
    snprintf(buf, n, "%s: %s", r->function, r->check ? r->check : "");
    return buf;
}

static void write_junit(const char *path)
{
    FILE *f = open_out(path);
    if (!f) return;
    /* suites in first-appearance order: "<dll>.L<level>" */
    smap_t idx = { 0 };
    int nsuites = 0;
    char **sname = NULL;
    int *stests = NULL, *sfail = NULL, *sskip = NULL;
    int *suite_of = xmalloc(sizeof(int) * (g_nrec ? g_nrec : 1));
    int tests = 0, failures = 0, skipped = 0;
    for (size_t i = 0; i < g_nrec; i++) {
        rec_t *r = &g_recs[i];
        suite_of[i] = -1;
        if (r->is_export) continue;
        char k[400];
        snprintf(k, sizeof k, "%s.L%d", r->dll, r->level);
        int *v = smap_find(&idx, k);
        int s;
        if (v) s = *v;
        else {
            s = nsuites++;
            smap_put(&idx, k, s);
            sname = xrealloc(sname, sizeof(char *) * (size_t)nsuites);
            stests = xrealloc(stests, sizeof(int) * (size_t)nsuites);
            sfail = xrealloc(sfail, sizeof(int) * (size_t)nsuites);
            sskip = xrealloc(sskip, sizeof(int) * (size_t)nsuites);
            sname[s] = xstrdup(k);
            stests[s] = sfail[s] = sskip[s] = 0;
        }
        suite_of[i] = s;
        stests[s]++;
        tests++;
        if (r->verdict == V_FAIL) sfail[s]++, failures++;
        if (r->verdict == V_SKIP) sskip[s]++, skipped++;
    }
    fprintf(f, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    fprintf(f, "<testsuites name=\"apiprobe ");
    xml_esc(f, opt.target);
    fputc(' ', f);
    xml_esc(f, opt.winver);
    fprintf(f, "\" tests=\"%d\" failures=\"%d\" skipped=\"%d\">\n", tests, failures, skipped);
    for (int s = 0; s < nsuites; s++) {
        fprintf(f, "  <testsuite name=\"");
        xml_esc(f, sname[s]);
        fprintf(f, "\" tests=\"%d\" failures=\"%d\" errors=\"0\" skipped=\"%d\">\n", stests[s], sfail[s], sskip[s]);
        for (size_t i = 0; i < g_nrec; i++) {
            if (suite_of[i] != s) continue;
            rec_t *r = &g_recs[i];
            char nb[512];
            fprintf(f, "    <testcase classname=\"");
            xml_esc(f, opt.target);
            fputc('-', f);
            xml_esc(f, opt.winver);
            fputc('.', f);
            xml_esc(f, r->dll);
            fprintf(f, "\" name=\"");
            xml_esc(f, case_name(r, nb, sizeof nb));
            fprintf(f, "\" time=\"%.3f\">\n", r->ms / 1000.0);
            if (r->verdict == V_FAIL) {
                fprintf(f, "      <failure message=\"%s (win32 %lu)\">expected %s by baseline",
                        STATUS_NAMES[r->status], (unsigned long)r->err, STATUS_NAMES[r->baseline]);
                if (r->detail && *r->detail) { fputs("; ", f); xml_esc(f, r->detail); }
                if (r->level == 2 && r->n_export) {
                    int listed = 0;
                    fputs("\nregressed exports:", f);
                    for (int e = 0; e < r->n_export && listed < 300; e++) {
                        rec_t *x = &g_recs[r->first_export + e];
                        if (x->verdict != V_FAIL) continue;
                        fputc(' ', f);
                        xml_esc(f, x->function);
                        listed++;
                    }
                }
                fputs("</failure>\n", f);
            } else if (r->verdict == V_SKIP) {
                fprintf(f, "      <skipped message=\"%s (win32 %lu), expected by baseline\"/>\n",
                        STATUS_NAMES[r->status], (unsigned long)r->err);
            }
            if (r->level == 2 || r->verdict == V_IMPROVED || (r->detail && *r->detail)) {
                fputs("      <system-out>", f);
                if (r->verdict == V_IMPROVED && r->level != 2) {
                    fprintf(f, "improved: was %s; ", STATUS_NAMES[r->baseline]);
                }
                if (r->level == 2) {
                    fprintf(f, "%d/%d exports resolved", r->resolved, r->total);
                    if (r->improved) { fputs("; improved: ", f); xml_esc(f, r->improved); }
                    if (r->n_export) {
                        int listed = 0;
                        fputs("; missing:", f);
                        for (int e = 0; e < r->n_export && listed < 300; e++, listed++) {
                            fputc(' ', f);
                            xml_esc(f, g_recs[r->first_export + e].function);
                        }
                        if (r->n_export > 300) fputs(" ...", f);
                    }
                    if (r->detail && *r->detail) fputs("; ", f);
                }
                xml_esc(f, r->detail);
                fputs("</system-out>\n", f);
            }
            fputs("    </testcase>\n", f);
        }
        fputs("  </testsuite>\n", f);
    }
    fputs("</testsuites>\n", f);
    fclose(f);
}

static const char *VERDICTS[] = { "pass", "skip", "fail", "improved" };

static void write_jsonl(const char *path)
{
    FILE *f = open_out(path);
    if (!f) return;
    for (size_t i = 0; i < g_nrec; i++) {
        rec_t *r = &g_recs[i];
        fputs("{\"target\":", f);
        json_esc(f, opt.target);
        fputs(",\"windows_version\":", f);
        json_esc(f, opt.winver);
        fputs(",\"os_build\":", f);
        json_esc(f, g_os_build);
        fprintf(f, ",\"level\":%d,\"dll\":", r->level);
        json_esc(f, r->dll);
        fputs(",\"function\":", f);
        json_esc(f, r->function ? r->function : (r->level == 2 ? "*" : ""));
        fputs(",\"check\":", f);
        json_esc(f, r->level == 1 ? "load" : r->level == 2 ? (r->is_export ? "resolve" : "exports") : r->check);
        fprintf(f, ",\"status\":\"%s\",\"win32_error\":%lu,\"ms\":%.3f,\"baseline\":\"%s\",\"verdict\":\"%s\"",
                STATUS_NAMES[r->status], (unsigned long)r->err, r->ms, STATUS_NAMES[r->baseline], VERDICTS[r->verdict]);
        if (r->level == 2 && !r->is_export) fprintf(f, ",\"resolved\":%d,\"total\":%d", r->resolved, r->total);
        if (r->probe_id) { fputs(",\"id\":", f); json_esc(f, r->probe_id); }
        if (r->detail && *r->detail) { fputs(",\"detail\":", f); json_esc(f, r->detail); }
        fputs("}\n", f);
    }
    fclose(f);
}

static int cmp_str(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

static void write_baseline(const char *path)
{
    FILE *f = open_out(path);
    if (!f) return;
    char **lines = NULL;
    size_t n = 0;
    for (size_t i = 0; i < g_nrec; i++) {
        rec_t *r = &g_recs[i];
        if (r->status == ST_OK || r->status == ST_SKIP) continue;
        if (r->level == 2 && !r->is_export) continue;
        char key[700];
        rec_key(r, key, sizeof key);
        size_t l = strlen(key);
        snprintf(key + l, sizeof key - l, " = %s", STATUS_NAMES[r->status]);
        lines = xrealloc(lines, sizeof(char *) * (n + 1));
        lines[n++] = xstrdup(key);
    }
    qsort(lines, n, sizeof(char *), cmp_str);
    fprintf(f, "# apiprobe baseline: %s %s (os_build %s)\n", opt.target, opt.winver, g_os_build);
    fprintf(f, "# One line per probe that is not expected to be ok; unlisted probes are expected ok.\n");
    fprintf(f, "# Regenerate with: apiprobe.exe --level all --write-baseline <file> (see api-tests/README.md)\n");
    for (size_t i = 0; i < n; i++) {
        fprintf(f, "%s\n", lines[i]);
        free(lines[i]);
    }
    free(lines);
    fclose(f);
    printf("# wrote baseline %s (%u lines)\n", path, (unsigned)n);
}

/* ------------------------------------------------------------------------ */
/* main                                                                     */

static void usage(void)
{
    puts("usage: apiprobe.exe [--level 1|2|3|all] [--filter <glob>[,<glob>...]] [--data DIR]\n"
         "                    [--timeout-ms N] [--junit FILE] [--jsonl FILE]\n"
         "                    [--target NAME] [--windows-version V] [--network]\n"
         "                    [--baseline FILE] [--write-baseline FILE]\n"
         "       apiprobe.exe --list\n"
         "       apiprobe.exe --child <probe-id> [--network]   (internal)\n"
         "Probe ids for --filter: 'L1 <dll>', 'L2 <dll>', 'L3 <dll>.<Function>'.");
}

static const char *env_or(const char *name, const char *def)
{
    static char buf[4][256];
    static int k;
    DWORD n = GetEnvironmentVariableA(name, buf[k & 3], sizeof buf[0]);
    if (n && n < sizeof buf[0]) return buf[(k++) & 3];
    return def;
}

int wmain(int argc, wchar_t **wargv)
{
    char **argv = xmalloc(sizeof(char *) * (size_t)(argc + 1));
    for (int i = 0; i < argc; i++) argv[i] = w2u(wargv[i]);
    argv[argc] = NULL;

    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--network")) g_network = 1;

    if (argc >= 3 && !strcmp(argv[1], "--sleep")) {
        Sleep((DWORD)strtoul(argv[2], NULL, 10));
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "--child")) {
        child_setup();
        return child_l3(argv[2]);
    }
    if (argc >= 4 && !strcmp(argv[1], "--child-dlls")) {
        child_setup();
        return child_dlls(atoi(argv[2]), wargv[3], argc - 4, wargv + 4);
    }
    if (argc >= 2 && !strcmp(argv[1], "--list")) {
        for (int t = 0; TABLES[t]; t++)
            for (const probe_t *p = TABLES[t]; p->id; p++)
                printf("L3 %s\t%s!%s: %s%s\n", p->id, p->dll, p->function, p->check,
                       p->needs_network ? " (network)" : "");
        return 0;
    }

    opt.levels = (1 << 1) | (1 << 2) | (1 << 3);
    opt.timeout_ms = 30000;
    opt.target = env_or("APIPROBE_TARGET", "unknown");
    opt.winver = env_or("APIPROBE_WINDOWS_VERSION", "unknown");
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--network")) continue;
        if (!strcmp(a, "--help") || !strcmp(a, "-h") || !strcmp(a, "/?")) { usage(); return 0; }
        if (!v) { fprintf(stderr, "apiprobe: %s needs a value\n", a); usage(); return 2; }
        i++;
        if (!strcmp(a, "--level")) {
            if (!strcmp(v, "all")) opt.levels = (1 << 1) | (1 << 2) | (1 << 3);
            else {
                opt.levels = 0;
                for (const char *c = v; *c; c++)
                    if (*c >= '1' && *c <= '3') opt.levels |= 1 << (*c - '0');
            }
            if (opt.levels & (1 << 2)) opt.levels |= 1 << 1; /* L2 needs L1 */
        } else if (!strcmp(a, "--filter")) opt.filter = v;
        else if (!strcmp(a, "--data")) opt.data_dir = wargv[i];
        else if (!strcmp(a, "--timeout-ms")) opt.timeout_ms = (DWORD)strtoul(v, NULL, 10);
        else if (!strcmp(a, "--junit")) opt.junit = v;
        else if (!strcmp(a, "--jsonl")) opt.jsonl = v;
        else if (!strcmp(a, "--target")) opt.target = v;
        else if (!strcmp(a, "--windows-version")) opt.winver = v;
        else if (!strcmp(a, "--baseline")) opt.baseline = v;
        else if (!strcmp(a, "--write-baseline")) opt.write_baseline = v;
        else { fprintf(stderr, "apiprobe: unknown option %s\n", a); usage(); return 2; }
    }
    if (!opt.data_dir) {
        static wchar_t dd[MAX_PATH * 2];
        GetModuleFileNameW(NULL, dd, MAX_PATH * 2);
        wchar_t *slash = wcsrchr(dd, L'\\');
        if (slash) *slash = 0;
        wcscat(dd, L"\\data");
        opt.data_dir = dd;
    }
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    os_build_string(g_os_build, sizeof g_os_build);

    printf("TAP version 13\n");
    printf("# apiprobe target=%s windows_version=%s os_build=%s network=%d\n", opt.target, opt.winver,
           g_os_build, g_network);
    if (opt.baseline) {
        int n = load_baseline(opt.baseline);
        if (n == 0) printf("# baseline %s is missing or empty: every probe is expected ok\n", opt.baseline);
        else printf("# baseline %s: %d expected non-ok probes\n", opt.baseline, n);
    }
    double t0 = now_ms();
    if (opt.levels & (1 << 1)) run_l1_l2();
    if (opt.levels & (1 << 3)) run_l3();
    find_l2_improvements();
    printf("1..%d\n", g_tap_n);
    printf("# %d tests, %d regressions, %d expected non-ok (skipped), %d improvements, %.1f s\n", g_tap_n,
           g_fail, g_skip, g_improved, (now_ms() - t0) / 1000.0);
    if (opt.junit) write_junit(opt.junit);
    if (opt.jsonl) write_jsonl(opt.jsonl);
    if (opt.write_baseline) write_baseline(opt.write_baseline);
    if (g_fail) printf("::error title=apiprobe regressions::%d result(s) worse than the baseline for %s %s\n",
                       g_fail, opt.target, opt.winver);
    fflush(stdout);
    return g_fail ? 1 : 0;
}
