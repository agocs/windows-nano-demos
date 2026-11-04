/* probes_crt.c - C runtime probes and the load-only list. */
#include "probes.h"
#include <locale.h>
#include <time.h>

typedef FILE *(__cdecl *wfopen_t)(const wchar_t *, const wchar_t *);
typedef int (__cdecl *fclose_t)(FILE *);
typedef char *(__cdecl *setlocale_t)(int, const char *);
typedef size_t (__cdecl *strftime_t)(char *, size_t, const char *, const struct tm *);
typedef uintptr_t (__cdecl *beginthreadex_t)(void *, unsigned, unsigned (__stdcall *)(void *), void *, unsigned, unsigned *);

static void crt_wfopen(result_t *r, const char *dll, const char *id)
{
    wfopen_t wf = need_(r, dll, "_wfopen");
    if (!wf) return;
    fclose_t fc = need_(r, dll, "fclose");
    if (!fc) return;
    wchar_t dir[MAX_PATH], path[MAX_PATH];
    if (!probe_tmpdir(r, id, dir, MAX_PATH)) return;
    _snwprintf(path, MAX_PATH, L"%ls\\f.txt", dir);
    FILE *f = wf(path, L"w");
    if (!f) fail(r, "_wfopen");
    else { fc(f); ok(r, "file opened and closed"); }
    rm_tree(dir);
}

static void crt_setlocale(result_t *r, const char *dll)
{
    setlocale_t sl = need_(r, dll, "setlocale");
    if (!sl) return;
    char *s = sl(LC_ALL, ".UTF8");
    if (!s) { fail_code(r, 0, "setlocale(LC_ALL, \".UTF8\") returned NULL"); return; }
    char copy[128];
    snprintf(copy, sizeof copy, "%s", s);
    sl(LC_ALL, "C");
    ok(r, "%s", copy);
}

static void p_msvcrt_wfopen(result_t *r) { crt_wfopen(r, "msvcrt", "msvcrt_wfopen"); }
static void p_msvcrt_setlocale(result_t *r) { crt_setlocale(r, "msvcrt"); }
static void p_ucrt_wfopen(result_t *r) { crt_wfopen(r, "ucrtbase", "ucrt_wfopen"); }
static void p_ucrt_setlocale(result_t *r) { crt_setlocale(r, "ucrtbase"); }

static void p_strftime(result_t *r)
{
    strftime_t sf = need_(r, "msvcrt", "strftime");
    if (!sf) return;
    struct tm t;
    memset(&t, 0, sizeof t);
    t.tm_year = 124;
    t.tm_mon = 1;
    t.tm_mday = 29;
    char buf[64];
    if (!sf(buf, sizeof buf, "%Y-%m-%d", &t) || strcmp(buf, "2024-02-29")) { fail_code(r, 0, "strftime"); return; }
    ok(r, "2024-02-29");
}

static unsigned __stdcall crt_thread(void *p)
{
    *(int *)p = 7;
    return 3;
}

static void p_beginthreadex(result_t *r)
{
    beginthreadex_t bt = need_(r, "msvcrt", "_beginthreadex");
    if (!bt) return;
    static int v;
    uintptr_t h = bt(NULL, 0, crt_thread, &v, 0, NULL);
    if (!h) { fail(r, "_beginthreadex"); return; }
    WaitForSingleObject((HANDLE)h, 2000);
    DWORD code = 0;
    GetExitCodeThread((HANDLE)h, &code);
    CloseHandle((HANDLE)h);
    if (v != 7 || code != 3) fail_code(r, 0, "thread did not run");
    else ok(r, "thread ran");
}

const probe_t probes_crt[] = {
    PROBE(msvcrt, _wfopen, "open a temp file", 0, p_msvcrt_wfopen),
    PROBE(msvcrt, setlocale, "LC_ALL .UTF8", 0, p_msvcrt_setlocale),
    PROBE(msvcrt, strftime, "%Y-%m-%d", 0, p_strftime),
    PROBE(msvcrt, _beginthreadex, "thread runs", 0, p_beginthreadex),
    PROBE(ucrtbase, _wfopen, "open a temp file", 0, p_ucrt_wfopen),
    PROBE(ucrtbase, setlocale, "LC_ALL .UTF8", 0, p_ucrt_setlocale),
    PROBE_LOAD(vcruntime140),
    PROBE_LOAD(msvcp140),
    PROBE_END
};

const probe_t probes_loadonly[] = {
    PROBE(comctl32, InitCommonControlsEx, "load and resolve only", 0, NULL),
    PROBE(comdlg32, GetOpenFileNameW, "load and resolve only", 0, NULL),
    PROBE(uxtheme, OpenThemeData, "load and resolve only", 0, NULL),
    PROBE(dwmapi, DwmIsCompositionEnabled, "load and resolve only", 0, NULL),
    PROBE(gdiplus, GdiplusStartup, "load and resolve only", 0, NULL),
    PROBE(windowscodecs, WICCreateImagingFactory_Proxy, "load and resolve only", 0, NULL),
    PROBE(d3d11, D3D11CreateDevice, "load and resolve only", 0, NULL),
    PROBE(dxgi, CreateDXGIFactory1, "load and resolve only", 0, NULL),
    PROBE(opengl32, wglCreateContext, "load and resolve only", 0, NULL),
    PROBE(riched20, CreateTextServices, "load and resolve only", 0, NULL),
    PROBE(msi, MsiOpenDatabaseW, "load and resolve only", 0, NULL),
    PROBE(mscoree, CLRCreateInstance, "load and resolve only", 0, NULL),
    PROBE(odbc32, SQLAllocHandle, "load and resolve only", 0, NULL),
    PROBE(winscard, SCardEstablishContext, "load and resolve only", 0, NULL),
    PROBE(credui, CredUIPromptForCredentialsW, "load and resolve only", 0, NULL),
    PROBE(taskschd, DllGetClassObject, "load and resolve only", 0, NULL),
    PROBE_LOAD(clbcatq),
    PROBE(avrt, AvSetMmThreadCharacteristicsW, "load and resolve only", 0, NULL),
    PROBE(hid, HidD_GetHidGuid, "load and resolve only", 0, NULL),
    PROBE(winusb, WinUsb_Initialize, "load and resolve only", 0, NULL),
    PROBE_END
};
