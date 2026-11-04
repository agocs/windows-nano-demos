/* probes_shell.c - shell32, shlwapi and shcore probes. */
#include "probes.h"
#include <shellapi.h>
#include <shlobj.h>

#define SH "shell32"
#define SHL "shlwapi"

typedef HRESULT (WINAPI *SHGetKnownFolderPath_t)(const GUID *, DWORD, HANDLE, PWSTR *);
typedef void (WINAPI *CoTaskMemFree_t)(void *);
typedef HRESULT (WINAPI *SHGetFolderPathW_t)(HWND, int, HANDLE, DWORD, LPWSTR);
typedef LPWSTR (WINAPI *PathCombineW_t)(LPWSTR, LPCWSTR, LPCWSTR);
typedef BOOL (WINAPI *PathFileExistsW_t)(LPCWSTR);
typedef PWSTR (WINAPI *StrStrIW_t)(PCWSTR, PCWSTR);
typedef LONG (WINAPI *SHGetValueW_t)(HKEY, LPCWSTR, LPCWSTR, DWORD *, void *, DWORD *);

static const GUID FOLDERID_RoamingAppData_ = { 0x3EB685DB, 0x65F9, 0x4CF6, { 0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D } };

static void p_SHGetKnownFolderPath(result_t *r)
{
    NEEDT(SH, SHGetKnownFolderPath_t, SHGetKnownFolderPath);
    NEEDT("ole32", CoTaskMemFree_t, CoTaskMemFree);
    PWSTR p = NULL;
    HRESULT hr = SHGetKnownFolderPath(&FOLDERID_RoamingAppData_, 0, NULL, &p);
    if (FAILED(hr) || !p) { fail_code(r, (DWORD)hr, "hr 0x%08lx", (unsigned long)hr); return; }
    int good = p[1] == L':';
    CoTaskMemFree(p);
    if (!good) fail_code(r, 0, "not a drive path");
    else ok(r, "FOLDERID_RoamingAppData resolved");
}

static void p_SHGetFolderPathW(result_t *r)
{
    NEEDT(SH, SHGetFolderPathW_t, SHGetFolderPathW);
    wchar_t buf[MAX_PATH];
    HRESULT hr = SHGetFolderPathW(NULL, 0x0028 /* CSIDL_PROFILE */, NULL, 0, buf);
    if (FAILED(hr)) { fail_code(r, (DWORD)hr, "hr 0x%08lx", (unsigned long)hr); return; }
    ok(r, "CSIDL_PROFILE resolved");
}

static void p_CommandLineToArgvW(result_t *r)
{
    NEED(SH, CommandLineToArgvW);
    int n = 0;
    LPWSTR *v = CommandLineToArgvW(L"a \"b c\" d", &n);
    if (!v) { fail(r, "CommandLineToArgvW"); return; }
    int good = n == 3 && !wcscmp(v[1], L"b c");
    LocalFree(v);
    if (!good) fail_code(r, 0, "split into %d", n);
    else ok(r, "3 arguments");
}

static void p_ShellExecuteExW(result_t *r)
{
    NEED(SH, ShellExecuteExW);
    wchar_t cmd[MAX_PATH];
    sys32_path(L"cmd.exe", cmd, MAX_PATH);
    SHELLEXECUTEINFOW sei;
    memset(&sei, 0, sizeof sei);
    sei.cbSize = sizeof sei;
    sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
    sei.lpVerb = L"open";
    sei.lpFile = cmd;
    sei.lpParameters = L"/c exit 0";
    sei.nShow = SW_HIDE;
    if (!ShellExecuteExW(&sei)) { fail(r, "ShellExecuteExW"); return; }
    DWORD code = sei.hProcess ? wait_exit(sei.hProcess, 5000) : (DWORD)-2;
    if (sei.hProcess) CloseHandle(sei.hProcess);
    if (code != 0) fail_code(r, code, "exit code %ld", (long)code);
    else ok(r, "cmd.exe ran, exit 0");
}

static void p_SHFileOperationW(result_t *r)
{
    NEED(SH, SHFileOperationW);
    wchar_t dir[MAX_PATH], from[MAX_PATH + 2], to[MAX_PATH + 2];
    if (!probe_tmpdir(r, "SHFileOperationW", dir, MAX_PATH)) return;
    memset(from, 0, sizeof from);
    memset(to, 0, sizeof to);
    _snwprintf(from, MAX_PATH, L"%ls\\a.txt", dir);
    _snwprintf(to, MAX_PATH, L"%ls\\b.txt", dir);
    HANDLE h = CreateFileW(from, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { fail(r, "CreateFileW"); rm_tree(dir); return; }
    CloseHandle(h);
    SHFILEOPSTRUCTW op;
    memset(&op, 0, sizeof op);
    op.wFunc = FO_COPY;
    op.pFrom = from;
    op.pTo = to;
    op.fFlags = FOF_NO_UI;
    int rc = SHFileOperationW(&op);
    if (rc) fail_code(r, (DWORD)rc, "SHFileOperationW returned %d", rc);
    else if (GetFileAttributesW(to) == INVALID_FILE_ATTRIBUTES) fail(r, "copy missing");
    else ok(r, "file copied");
    rm_tree(dir);
}

static void p_PathCombineW(result_t *r)
{
    NEEDT(SHL, PathCombineW_t, PathCombineW);
    NEEDT(SHL, PathFileExistsW_t, PathFileExistsW);
    NEEDT(SHL, StrStrIW_t, StrStrIW);
    wchar_t buf[MAX_PATH], sys[MAX_PATH];
    GetSystemDirectoryW(sys, MAX_PATH);
    if (!PathCombineW(buf, sys, L"cmd.exe")) { fail(r, "PathCombineW"); return; }
    if (!PathFileExistsW(buf)) { fail(r, "PathFileExistsW"); return; }
    if (!StrStrIW(buf, L"CMD.EXE")) { fail_code(r, 0, "StrStrIW"); return; }
    ok(r, "PathCombineW, PathFileExistsW, StrStrIW");
}

static void p_SHGetValueW(result_t *r)
{
    NEEDT(SHL, SHGetValueW_t, SHGetValueW);
    wchar_t buf[64];
    DWORD type, cb = sizeof buf;
    LONG e = SHGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", L"CurrentBuild", &type, buf, &cb);
    if (e) { fail_code(r, (DWORD)e, "SHGetValueW"); return; }
    ok(r, "CurrentBuild read");
}

const probe_t probes_shell[] = {
    PROBE(shell32, SHGetKnownFolderPath, "FOLDERID_RoamingAppData", 0, p_SHGetKnownFolderPath),
    PROBE(shell32, SHGetFolderPathW, "CSIDL_PROFILE", 0, p_SHGetFolderPathW),
    PROBE(shell32, CommandLineToArgvW, "a \"b c\" d splits into 3", 0, p_CommandLineToArgvW),
    PROBE(shell32, ShellExecuteExW, "open cmd.exe /c exit 0", 0, p_ShellExecuteExW),
    PROBE(shell32, SHFileOperationW, "FO_COPY of a temp file", 0, p_SHFileOperationW),
    PROBE(shlwapi, PathCombineW, "PathCombineW, PathFileExistsW, StrStrIW", 0, p_PathCombineW),
    PROBE(shlwapi, SHGetValueW, "HKLM CurrentBuild", 0, p_SHGetValueW),
    PROBE(shcore, GetDpiForMonitor, "load and resolve only", 0, NULL),
    PROBE_END
};
