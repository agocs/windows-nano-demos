/* probes_diag.c - dbghelp, psapi, version, pdh and wevtapi probes, and the
 * accounts / setup / multimedia probes (netapi32, userenv, secur32, setupapi, winmm). */
#include "probes.h"

int apiprobe_marker(int x);

typedef BOOL (WINAPI *SymInitializeW_t)(HANDLE, PCWSTR, BOOL);
typedef BOOL (WINAPI *SymCleanup_t)(HANDLE);
typedef DWORD (WINAPI *SymSetOptions_t)(DWORD);
typedef struct {
    ULONG SizeOfStruct, TypeIndex;
    ULONG64 Reserved[2];
    ULONG Index, Size;
    ULONG64 ModBase;
    ULONG Flags;
    ULONG64 Value, Address;
    ULONG Register, Scope, Tag, NameLen, MaxNameLen;
    WCHAR Name[1];
} symbol_infow_t;
typedef BOOL (WINAPI *SymFromAddrW_t)(HANDLE, DWORD64, DWORD64 *, symbol_infow_t *);
typedef BOOL (WINAPI *MiniDumpWriteDump_t)(HANDLE, DWORD, HANDLE, int, void *, void *, void *);

static void p_SymFromAddrW(result_t *r)
{
    NEEDT("dbghelp", SymInitializeW_t, SymInitializeW);
    NEEDT("dbghelp", SymFromAddrW_t, SymFromAddrW);
    NEEDT("dbghelp", SymCleanup_t, SymCleanup);
    NEEDT("dbghelp", SymSetOptions_t, SymSetOptions);
    HANDLE p = GetCurrentProcess();
    SymSetOptions(0x00000002 /* SYMOPT_UNDNAME */ | 0x00000004 /* DEFERRED_LOADS */);
    if (!SymInitializeW(p, NULL, TRUE)) { fail(r, "SymInitializeW"); return; }
    static union { symbol_infow_t s; BYTE b[sizeof(symbol_infow_t) + 512]; } u;
    memset(&u, 0, sizeof u);
    u.s.SizeOfStruct = sizeof(symbol_infow_t);
    u.s.MaxNameLen = 250;
    DWORD64 disp = 0;
    BOOL b = SymFromAddrW(p, (DWORD64)(ULONG_PTR)(void *)apiprobe_marker, &disp, &u.s);
    DWORD e = GetLastError();
    SymCleanup(p);
    if (!b) { fail_code(r, e, "SymFromAddrW"); return; }
    if (!wcsstr(u.s.Name, L"apiprobe_marker")) { fail_code(r, 0, "wrong symbol name"); return; }
    ok(r, "found apiprobe_marker");
}

static void p_MiniDumpWriteDump(result_t *r)
{
    NEEDT("dbghelp", MiniDumpWriteDump_t, MiniDumpWriteDump);
    wchar_t dir[MAX_PATH], path[MAX_PATH];
    if (!probe_tmpdir(r, "MiniDumpWriteDump", dir, MAX_PATH)) return;
    _snwprintf(path, MAX_PATH, L"%ls\\child.dmp", dir);
    PROCESS_INFORMATION pi;
    if (!start_sleeper(30000, 0, &pi)) { fail(r, "start child"); rm_tree(dir); return; }
    Sleep(100);
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) fail(r, "CreateFileW");
    else {
        BOOL b = MiniDumpWriteDump(pi.hProcess, pi.dwProcessId, f, 0 /* MiniDumpNormal */, NULL, NULL, NULL);
        DWORD e = GetLastError();
        LARGE_INTEGER sz = { 0 };
        GetFileSizeEx(f, &sz);
        CloseHandle(f);
        if (!b) fail_code(r, e, "MiniDumpWriteDump");
        else if (!sz.QuadPart) fail_code(r, 0, "empty dump");
        else ok(r, "%lld byte dump", sz.QuadPart);
    }
    TerminateProcess(pi.hProcess, 0);
    WaitForSingleObject(pi.hProcess, 2000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    rm_tree(dir);
}

typedef BOOL (WINAPI *EnumProcesses_t)(DWORD *, DWORD, DWORD *);
typedef DWORD (WINAPI *GetModuleFileNameExW_t)(HANDLE, HMODULE, LPWSTR, DWORD);

static void p_EnumProcesses(result_t *r)
{
    NEEDT("psapi", EnumProcesses_t, EnumProcesses);
    NEEDT("psapi", GetModuleFileNameExW_t, GetModuleFileNameExW);
    static DWORD pids[4096];
    DWORD cb = 0;
    if (!EnumProcesses(pids, sizeof pids, &cb)) { fail(r, "EnumProcesses"); return; }
    int found = 0;
    for (DWORD i = 0; i < cb / sizeof(DWORD); i++) found |= pids[i] == GetCurrentProcessId();
    if (!found) { fail_code(r, 0, "own pid missing"); return; }
    wchar_t buf[MAX_PATH * 2];
    if (!GetModuleFileNameExW(GetCurrentProcess(), NULL, buf, MAX_PATH * 2)) { fail(r, "GetModuleFileNameExW"); return; }
    ok(r, "%lu processes, own image name read", cb / (DWORD)sizeof(DWORD));
}

typedef DWORD (WINAPI *GetFileVersionInfoSizeW_t)(LPCWSTR, DWORD *);
typedef BOOL (WINAPI *GetFileVersionInfoW_t)(LPCWSTR, DWORD, DWORD, void *);
typedef BOOL (WINAPI *VerQueryValueW_t)(const void *, LPCWSTR, void **, UINT *);

static void p_VerQueryValueW(result_t *r)
{
    NEEDT("version", GetFileVersionInfoSizeW_t, GetFileVersionInfoSizeW);
    NEEDT("version", GetFileVersionInfoW_t, GetFileVersionInfoW);
    NEEDT("version", VerQueryValueW_t, VerQueryValueW);
    wchar_t path[MAX_PATH];
    sys32_path(L"kernelbase.dll", path, MAX_PATH);
    DWORD h = 0, n = GetFileVersionInfoSizeW(path, &h);
    if (!n) { fail(r, "GetFileVersionInfoSizeW"); return; }
    void *buf = HeapAlloc(GetProcessHeap(), 0, n);
    VS_FIXEDFILEINFO *fi = NULL;
    UINT len = 0;
    if (!GetFileVersionInfoW(path, 0, n, buf)) fail(r, "GetFileVersionInfoW");
    else if (!VerQueryValueW(buf, L"\\", (void **)&fi, &len) || !fi) fail(r, "VerQueryValueW");
    else ok(r, "kernelbase %lu.%lu.%lu.%lu", HIWORD(fi->dwFileVersionMS), LOWORD(fi->dwFileVersionMS),
            HIWORD(fi->dwFileVersionLS), LOWORD(fi->dwFileVersionLS));
    HeapFree(GetProcessHeap(), 0, buf);
}

typedef LONG (WINAPI *PdhOpenQueryW_t)(LPCWSTR, DWORD_PTR, void **);
typedef LONG (WINAPI *PdhAddEnglishCounterW_t)(void *, LPCWSTR, DWORD_PTR, void **);
typedef LONG (WINAPI *PdhCloseQuery_t)(void *);

static void p_PdhAddEnglishCounterW(result_t *r)
{
    NEEDT("pdh", PdhOpenQueryW_t, PdhOpenQueryW);
    NEEDT("pdh", PdhAddEnglishCounterW_t, PdhAddEnglishCounterW);
    NEEDT("pdh", PdhCloseQuery_t, PdhCloseQuery);
    void *q = NULL, *c = NULL;
    LONG e = PdhOpenQueryW(NULL, 0, &q);
    if (e) { fail_code(r, (DWORD)e, "PdhOpenQueryW 0x%08lx", (unsigned long)e); return; }
    e = PdhAddEnglishCounterW(q, L"\\Processor(_Total)\\% Processor Time", 0, &c);
    PdhCloseQuery(q);
    if (e) fail_code(r, (DWORD)e, "PdhAddEnglishCounterW 0x%08lx", (unsigned long)e);
    else ok(r, "processor time counter added");
}

typedef void *(WINAPI *EvtQuery_t)(void *, LPCWSTR, LPCWSTR, DWORD);
typedef BOOL (WINAPI *EvtClose_t)(void *);

static void p_EvtQuery(result_t *r)
{
    NEEDT("wevtapi", EvtQuery_t, EvtQuery);
    NEEDT("wevtapi", EvtClose_t, EvtClose);
    void *h = EvtQuery(NULL, L"System", NULL, 0x1 /* EvtQueryChannelPath */ | 0x200 /* ReverseDirection */);
    if (!h) { fail(r, "EvtQuery(System)"); return; }
    EvtClose(h);
    ok(r, "System channel query opened");
}

/* accounts, setup and multimedia */

typedef DWORD (WINAPI *NetGetJoinInformation_t)(LPCWSTR, LPWSTR *, int *);
typedef DWORD (WINAPI *NetApiBufferFree_t)(void *);
typedef BOOL (WINAPI *GetUserProfileDirectoryW_t)(HANDLE, LPWSTR, DWORD *);
typedef BOOLEAN (WINAPI *GetUserNameExW_t)(int, LPWSTR, ULONG *);
typedef struct { ULONG_PTR lower, upper; } cred_handle_t;
typedef LONG (WINAPI *AcquireCredentialsHandleW_t)(LPWSTR, LPWSTR, ULONG, void *, void *, void *, void *, cred_handle_t *, LARGE_INTEGER *);
typedef LONG (WINAPI *FreeCredentialsHandle_t)(cred_handle_t *);
typedef void *(WINAPI *SetupDiGetClassDevsW_t)(const GUID *, LPCWSTR, HWND, DWORD);
typedef BOOL (WINAPI *SetupDiDestroyDeviceInfoList_t)(void *);
typedef DWORD (WINAPI *timeGetTime_t)(void);
typedef UINT (WINAPI *timeBeginPeriod_t)(UINT);

static void p_NetGetJoinInformation(result_t *r)
{
    NEEDT("netapi32", NetGetJoinInformation_t, NetGetJoinInformation);
    NEEDT("netapi32", NetApiBufferFree_t, NetApiBufferFree);
    LPWSTR name = NULL;
    int st = 0;
    DWORD e = NetGetJoinInformation(NULL, &name, &st);
    if (e) { fail_code(r, e, "NetGetJoinInformation"); return; }
    NetApiBufferFree(name);
    ok(r, "join status %d", st);
}

static void p_GetUserProfileDirectoryW(result_t *r)
{
    NEEDT("userenv", GetUserProfileDirectoryW_t, GetUserProfileDirectoryW);
    NEED("advapi32", OpenProcessToken);
    HANDLE tok;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) { fail(r, "OpenProcessToken"); return; }
    wchar_t buf[MAX_PATH];
    DWORD n = MAX_PATH;
    BOOL b = GetUserProfileDirectoryW(tok, buf, &n);
    DWORD e = GetLastError();
    CloseHandle(tok);
    if (!b) fail_code(r, e, "GetUserProfileDirectoryW");
    else ok(r, "profile directory read");
}

static void p_GetUserNameExW(result_t *r)
{
    NEEDT("secur32", GetUserNameExW_t, GetUserNameExW);
    wchar_t buf[256];
    ULONG n = 256;
    if (!GetUserNameExW(2 /* NameSamCompatible */, buf, &n)) { fail(r, "GetUserNameExW(NameSamCompatible)"); return; }
    char s[256];
    WideCharToMultiByte(CP_UTF8, 0, buf, -1, s, sizeof s, NULL, NULL);
    ok(r, "%s", s);
}

static void p_AcquireCredentialsHandleW(result_t *r)
{
    NEEDT("secur32", AcquireCredentialsHandleW_t, AcquireCredentialsHandleW);
    NEEDT("secur32", FreeCredentialsHandle_t, FreeCredentialsHandle);
    cred_handle_t h;
    LARGE_INTEGER exp;
    LONG st = AcquireCredentialsHandleW(NULL, L"Negotiate", 2 /* SECPKG_CRED_OUTBOUND */, NULL, NULL, NULL, NULL, &h, &exp);
    if (st) { fail_code(r, (DWORD)st, "SECURITY_STATUS 0x%08lx", (unsigned long)st); return; }
    FreeCredentialsHandle(&h);
    ok(r, "Negotiate outbound credentials");
}

static void p_SetupDiGetClassDevsW(result_t *r)
{
    NEEDT("setupapi", SetupDiGetClassDevsW_t, SetupDiGetClassDevsW);
    NEEDT("setupapi", SetupDiDestroyDeviceInfoList_t, SetupDiDestroyDeviceInfoList);
    void *h = SetupDiGetClassDevsW(NULL, NULL, NULL, 0x4 /* DIGCF_ALLCLASSES */);
    if (h == INVALID_HANDLE_VALUE) { fail(r, "SetupDiGetClassDevsW"); return; }
    SetupDiDestroyDeviceInfoList(h);
    ok(r, "device info set created");
}

static void p_timeBeginPeriod(result_t *r)
{
    NEEDT("winmm", timeGetTime_t, timeGetTime);
    NEEDT("winmm", timeBeginPeriod_t, timeBeginPeriod);
    NEEDT("winmm", timeBeginPeriod_t, timeEndPeriod);
    if (timeBeginPeriod(1) != 0) { fail_code(r, 0, "timeBeginPeriod(1)"); return; }
    DWORD a = timeGetTime();
    Sleep(5);
    DWORD b = timeGetTime();
    timeEndPeriod(1);
    if (b == a) fail_code(r, 0, "timeGetTime did not advance");
    else ok(r, "timeGetTime advanced %lu ms", b - a);
}

const probe_t probes_diag[] = {
    PROBE(dbghelp, SymFromAddrW, "SymInitializeW, symbol of a function in apiprobe.exe", 0, p_SymFromAddrW),
    PROBE(dbghelp, MiniDumpWriteDump, "dump of a child process", 0, p_MiniDumpWriteDump),
    PROBE(psapi, EnumProcesses, "own PID, GetModuleFileNameExW", 0, p_EnumProcesses),
    PROBE(version, VerQueryValueW, "file version of kernelbase.dll", 0, p_VerQueryValueW),
    PROBE(pdh, PdhAddEnglishCounterW, "\\Processor(_Total)\\% Processor Time", 0, p_PdhAddEnglishCounterW),
    PROBE(wevtapi, EvtQuery, "System channel", 0, p_EvtQuery),
    PROBE_END
};

const probe_t probes_accounts[] = {
    PROBE(netapi32, NetGetJoinInformation, "join status", 0, p_NetGetJoinInformation),
    PROBE(userenv, GetUserProfileDirectoryW, "own profile directory", 0, p_GetUserProfileDirectoryW),
    PROBE(secur32, GetUserNameExW, "NameSamCompatible", 0, p_GetUserNameExW),
    PROBE(secur32, AcquireCredentialsHandleW, "Negotiate outbound", 0, p_AcquireCredentialsHandleW),
    PROBE(setupapi, SetupDiGetClassDevsW, "DIGCF_ALLCLASSES", 0, p_SetupDiGetClassDevsW),
    PROBE(winmm, timeBeginPeriod, "timeBeginPeriod(1), timeGetTime", 0, p_timeBeginPeriod),
    PROBE_END
};
