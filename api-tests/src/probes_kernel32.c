/* probes_kernel32.c - kernel32 / kernelbase / ntdll behaviour probes. */
#include "probes.h"
#include <tlhelp32.h>

#define K32 "kernel32"

static void p_GetVersionExW(result_t *r)
{
    NEED(K32, GetVersionExW);
    OSVERSIONINFOW vi;
    memset(&vi, 0, sizeof vi);
    vi.dwOSVersionInfoSize = sizeof vi;
    if (!GetVersionExW(&vi)) { fail(r, "GetVersionExW failed"); return; }
    DWORD ma, mi, bu;
    os_version(&ma, &mi, &bu);
    if (vi.dwMajorVersion != ma || vi.dwMinorVersion != mi || vi.dwBuildNumber != bu) {
        fail_code(r, 0, "GetVersionExW %lu.%lu.%lu != RtlGetVersion %lu.%lu.%lu", vi.dwMajorVersion,
                  vi.dwMinorVersion, vi.dwBuildNumber, ma, mi, bu);
        return;
    }
    ok(r, "%lu.%lu.%lu", ma, mi, bu);
}

static void p_RtlGetVersion(result_t *r)
{
    typedef LONG (WINAPI *fn_t)(OSVERSIONINFOW *);
    NEEDT("ntdll", fn_t, RtlGetVersion);
    OSVERSIONINFOW vi;
    memset(&vi, 0, sizeof vi);
    vi.dwOSVersionInfoSize = sizeof vi;
    LONG st = RtlGetVersion(&vi);
    if (st != 0 || vi.dwMajorVersion != 10) { fail_code(r, (DWORD)st, "major %lu", vi.dwMajorVersion); return; }
    ok(r, "%lu.%lu.%lu", vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber);
}

static void p_GetNativeSystemInfo(result_t *r)
{
    NEED(K32, GetNativeSystemInfo);
    SYSTEM_INFO si;
    memset(&si, 0, sizeof si);
    GetNativeSystemInfo(&si);
    if (si.wProcessorArchitecture != PROCESSOR_ARCHITECTURE_AMD64) {
        fail_code(r, 0, "architecture %u", si.wProcessorArchitecture);
        return;
    }
    ok(r, "amd64, %lu processors, page %lu", si.dwNumberOfProcessors, si.dwPageSize);
}

static void p_CreateFileW(result_t *r)
{
    NEED(K32, CreateFileW);
    NEED(K32, WriteFile);
    NEED(K32, ReadFile);
    NEED(K32, SetFilePointerEx);
    NEED(K32, GetFileSizeEx);
    wchar_t dir[MAX_PATH], path[MAX_PATH];
    if (!probe_tmpdir(r, "CreateFileW", dir, MAX_PATH)) return;
    _snwprintf(path, MAX_PATH, L"%ls\\data.bin", dir);
    static unsigned char buf[65536], back[65536];
    for (int i = 0; i < 65536; i++) buf[i] = (unsigned char)(i * 7 + 3);
    HANDLE h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { fail(r, "CreateFileW"); rm_tree(dir); return; }
    DWORD n = 0;
    LARGE_INTEGER zero = { 0 }, size = { 0 };
    if (!WriteFile(h, buf, sizeof buf, &n, NULL) || n != sizeof buf) fail(r, "WriteFile");
    else if (!GetFileSizeEx(h, &size) || size.QuadPart != 65536) fail(r, "GetFileSizeEx %lld", size.QuadPart);
    else if (!SetFilePointerEx(h, zero, NULL, FILE_BEGIN)) fail(r, "SetFilePointerEx");
    else if (!ReadFile(h, back, sizeof back, &n, NULL) || n != sizeof back) fail(r, "ReadFile");
    else if (memcmp(buf, back, sizeof buf)) fail_code(r, 0, "data differs");
    else ok(r, "64 KiB round trip");
    CloseHandle(h);
    rm_tree(dir);
}

static void p_FindFirstFileExW(result_t *r)
{
    NEED(K32, FindFirstFileExW);
    wchar_t dir[MAX_PATH], path[MAX_PATH];
    if (!probe_tmpdir(r, "FindFirstFileExW", dir, MAX_PATH)) return;
    _snwprintf(path, MAX_PATH, L"%ls\\needle.txt", dir);
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { fail(r, "CreateFileW"); rm_tree(dir); return; }
    CloseHandle(h);
    _snwprintf(path, MAX_PATH, L"%ls\\needle*", dir);
    WIN32_FIND_DATAW fd;
    HANDLE f = FindFirstFileExW(path, FindExInfoBasic, &fd, FindExSearchNameMatch, NULL, FIND_FIRST_EX_LARGE_FETCH);
    if (f == INVALID_HANDLE_VALUE) fail(r, "FindFirstFileExW");
    else {
        if (wcscmp(fd.cFileName, L"needle.txt")) fail_code(r, 0, "found the wrong file");
        else ok(r, "found needle.txt");
        FindClose(f);
    }
    rm_tree(dir);
}

static void p_GetFinalPathNameByHandleW(result_t *r)
{
    NEED(K32, GetFinalPathNameByHandleW);
    wchar_t sys[MAX_PATH], out[MAX_PATH * 2];
    self_path(sys, MAX_PATH);
    HANDLE h = CreateFileW(sys, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { fail(r, "CreateFileW"); return; }
    DWORD n = GetFinalPathNameByHandleW(h, out, MAX_PATH * 2, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(h);
    if (!n || n >= MAX_PATH * 2) { fail(r, "GetFinalPathNameByHandleW"); return; }
    if (wcsncmp(out, L"\\\\?\\", 4) || out[5] != L':') { fail_code(r, 0, "unexpected path"); return; }
    ok(r, "\\\\?\\ path, %lu chars", n);
}

static void p_CreateHardLinkW(result_t *r)
{
    NEED(K32, CreateHardLinkW);
    wchar_t dir[MAX_PATH], a[MAX_PATH], b[MAX_PATH];
    if (!probe_tmpdir(r, "CreateHardLinkW", dir, MAX_PATH)) return;
    _snwprintf(a, MAX_PATH, L"%ls\\a.txt", dir);
    _snwprintf(b, MAX_PATH, L"%ls\\b.txt", dir);
    HANDLE h = CreateFileW(a, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { fail(r, "CreateFileW"); rm_tree(dir); return; }
    CloseHandle(h);
    if (!CreateHardLinkW(b, a, NULL)) fail(r, "CreateHardLinkW");
    else if (GetFileAttributesW(b) == INVALID_FILE_ATTRIBUTES) fail(r, "link missing");
    else ok(r, "hard link exists");
    rm_tree(dir);
}

static void p_CreateSymbolicLinkW(result_t *r)
{
    NEED(K32, CreateSymbolicLinkW);
    wchar_t dir[MAX_PATH], a[MAX_PATH], b[MAX_PATH];
    if (!probe_tmpdir(r, "CreateSymbolicLinkW", dir, MAX_PATH)) return;
    _snwprintf(a, MAX_PATH, L"%ls\\a.txt", dir);
    _snwprintf(b, MAX_PATH, L"%ls\\b.txt", dir);
    HANDLE h = CreateFileW(a, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { fail(r, "CreateFileW"); rm_tree(dir); return; }
    CloseHandle(h);
    if (!CreateSymbolicLinkW(b, a, 0x2 /* SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE */)) fail(r, "CreateSymbolicLinkW");
    else if (!(GetFileAttributesW(b) & FILE_ATTRIBUTE_REPARSE_POINT)) fail(r, "not a reparse point");
    else ok(r, "symbolic link exists");
    rm_tree(dir);
}

typedef struct { wchar_t path[MAX_PATH]; } rdc_arg_t;

static DWORD WINAPI rdc_writer(void *p)
{
    Sleep(200);
    HANDLE h = CreateFileW(((rdc_arg_t *)p)->path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    return 0;
}

static void p_ReadDirectoryChangesW(result_t *r)
{
    NEED(K32, ReadDirectoryChangesW);
    NEED(K32, GetOverlappedResult);
    wchar_t dir[MAX_PATH];
    if (!probe_tmpdir(r, "ReadDirectoryChangesW", dir, MAX_PATH)) return;
    HANDLE d = CreateFileW(dir, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                           OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    if (d == INVALID_HANDLE_VALUE) { fail(r, "open dir"); rm_tree(dir); return; }
    static DWORD buf[4096];
    OVERLAPPED ov;
    memset(&ov, 0, sizeof ov);
    ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ReadDirectoryChangesW(d, buf, sizeof buf, FALSE, FILE_NOTIFY_CHANGE_FILE_NAME, NULL, &ov, NULL)) {
        fail(r, "ReadDirectoryChangesW");
    } else {
        static rdc_arg_t a;
        _snwprintf(a.path, MAX_PATH, L"%ls\\new.txt", dir);
        HANDLE t = CreateThread(NULL, 0, rdc_writer, &a, 0, NULL);
        DWORD w = WaitForSingleObject(ov.hEvent, 2000);
        DWORD n = 0;
        if (w != WAIT_OBJECT_0) { CancelIo(d); fail_code(r, WAIT_TIMEOUT, "no notification within 2 s"); }
        else if (!GetOverlappedResult(d, &ov, &n, FALSE) || n == 0) fail(r, "GetOverlappedResult");
        else {
            FILE_NOTIFY_INFORMATION *fi = (FILE_NOTIFY_INFORMATION *)buf;
            if (fi->FileNameLength == 14 && !wcsncmp(fi->FileName, L"new.txt", 7)) ok(r, "saw new.txt");
            else fail_code(r, 0, "unexpected notification");
        }
        if (t) { WaitForSingleObject(t, 2000); CloseHandle(t); }
    }
    CloseHandle(ov.hEvent);
    CloseHandle(d);
    rm_tree(dir);
}

static void p_CreateProcessW(result_t *r)
{
    NEED(K32, CreateProcessW);
    wchar_t cmd[MAX_PATH], line[MAX_PATH + 32];
    sys32_path(L"cmd.exe", cmd, MAX_PATH);
    _snwprintf(line, MAX_PATH + 32, L"\"%ls\" /c exit 7", cmd);
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    if (!CreateProcessW(cmd, line, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        fail(r, "CreateProcessW");
        return;
    }
    DWORD code = wait_exit(pi.hProcess, 5000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (code != 7) fail_code(r, code, "exit code %lu", code);
    else ok(r, "exit code 7");
}

static void p_CreatePipe(result_t *r)
{
    NEED(K32, CreatePipe);
    HANDLE rd, wr;
    if (!CreatePipe(&rd, &wr, NULL, 0)) { fail(r, "CreatePipe"); return; }
    char buf[16] = { 0 };
    DWORD n = 0;
    if (!WriteFile(wr, "hello", 5, &n, NULL)) fail(r, "WriteFile");
    else if (!ReadFile(rd, buf, 5, &n, NULL) || n != 5 || memcmp(buf, "hello", 5)) fail(r, "ReadFile");
    else ok(r, "anonymous pipe round trip");
    CloseHandle(rd);
    CloseHandle(wr);
}

static void p_CreateNamedPipeW(result_t *r)
{
    NEED(K32, CreateNamedPipeW);
    NEED(K32, ConnectNamedPipe);
    wchar_t name[96];
    _snwprintf(name, 96, L"\\\\.\\pipe\\apiprobe-%lu", GetCurrentProcessId());
    HANDLE s = CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1,
                                4096, 4096, 0, NULL);
    if (s == INVALID_HANDLE_VALUE) { fail(r, "CreateNamedPipeW"); return; }
    HANDLE c = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (c == INVALID_HANDLE_VALUE) { fail(r, "client CreateFileW"); CloseHandle(s); return; }
    if (!ConnectNamedPipe(s, NULL) && GetLastError() != ERROR_PIPE_CONNECTED) {
        fail(r, "ConnectNamedPipe");
    } else {
        char buf[16] = { 0 };
        DWORD n = 0;
        if (!WriteFile(c, "ping", 4, &n, NULL)) fail(r, "WriteFile");
        else if (!ReadFile(s, buf, sizeof buf, &n, NULL) || n != 4 || memcmp(buf, "ping", 4)) fail(r, "ReadFile");
        else ok(r, "named pipe message arrived");
    }
    CloseHandle(c);
    CloseHandle(s);
}

static DWORD WINAPI set_event_thread(void *p)
{
    SetEvent((HANDLE)p);
    return 42;
}

static void p_WaitForMultipleObjects(result_t *r)
{
    NEED(K32, CreateThread);
    NEED(K32, CreateEventW);
    NEED(K32, WaitForMultipleObjects);
    NEED(K32, CreateWaitableTimerW);
    NEED(K32, SetWaitableTimer);
    HANDLE ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ev) { fail(r, "CreateEventW"); return; }
    HANDLE t = CreateThread(NULL, 0, set_event_thread, ev, 0, NULL);
    if (!t) { fail(r, "CreateThread"); CloseHandle(ev); return; }
    HANDLE hs[2] = { t, ev };
    DWORD w = WaitForMultipleObjects(2, hs, TRUE, 2000);
    DWORD code = 0;
    GetExitCodeThread(t, &code);
    CloseHandle(t);
    CloseHandle(ev);
    if (w > WAIT_OBJECT_0 + 1 || code != 42) { fail(r, "wait %lu, thread exit %lu", w, code); return; }
    HANDLE tm = CreateWaitableTimerW(NULL, TRUE, NULL);
    if (!tm) { fail(r, "CreateWaitableTimerW"); return; }
    LARGE_INTEGER due;
    due.QuadPart = -500000; /* 50 ms */
    if (!SetWaitableTimer(tm, &due, 0, NULL, NULL, FALSE)) fail(r, "SetWaitableTimer");
    else if (WaitForSingleObject(tm, 2000) != WAIT_OBJECT_0) fail(r, "timer did not fire");
    else ok(r, "thread, event and timer signalled");
    CloseHandle(tm);
}

static void p_VirtualProtect(result_t *r)
{
    NEED(K32, VirtualAlloc);
    NEED(K32, VirtualProtect);
    NEED(K32, FlushInstructionCache);
    NEED(K32, VirtualFree);
    unsigned char *p = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!p) { fail(r, "VirtualAlloc"); return; }
    static const unsigned char stub[] = { 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 }; /* mov eax, 42; ret */
    memcpy(p, stub, sizeof stub);
    DWORD old;
    if (!VirtualProtect(p, 4096, PAGE_EXECUTE_READ, &old)) { fail(r, "VirtualProtect"); VirtualFree(p, 0, MEM_RELEASE); return; }
    if (!FlushInstructionCache(GetCurrentProcess(), p, sizeof stub)) { fail(r, "FlushInstructionCache"); VirtualFree(p, 0, MEM_RELEASE); return; }
    int (*fn)(void) = (int (*)(void))(void *)p;
    int v = fn();
    VirtualFree(p, 0, MEM_RELEASE);
    if (v != 42) fail_code(r, 0, "stub returned %d", v);
    else ok(r, "generated code ran");
}

static void p_CreateJobObjectW(result_t *r)
{
    NEED(K32, CreateJobObjectW);
    NEED(K32, AssignProcessToJobObject);
    NEED(K32, SetInformationJobObject);
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (!job) { fail(r, "CreateJobObjectW"); return; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION li;
    memset(&li, 0, sizeof li);
    li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &li, sizeof li)) {
        fail(r, "SetInformationJobObject");
        CloseHandle(job);
        return;
    }
    PROCESS_INFORMATION pi;
    if (!start_sleeper(30000, CREATE_SUSPENDED, &pi)) { fail(r, "start child"); CloseHandle(job); return; }
    if (!AssignProcessToJobObject(job, pi.hProcess)) {
        fail(r, "AssignProcessToJobObject");
        TerminateProcess(pi.hProcess, 1);
    } else {
        ResumeThread(pi.hThread);
        CloseHandle(job);
        job = NULL;
        if (WaitForSingleObject(pi.hProcess, 5000) == WAIT_OBJECT_0) ok(r, "child killed when the job closed");
        else { fail_code(r, WAIT_TIMEOUT, "child still running"); TerminateProcess(pi.hProcess, 1); }
    }
    if (job) CloseHandle(job);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
}

static void p_CreateToolhelp32Snapshot(result_t *r)
{
    NEED(K32, CreateToolhelp32Snapshot);
    NEED(K32, Process32FirstW);
    NEED(K32, Process32NextW);
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (s == INVALID_HANDLE_VALUE) { fail(r, "CreateToolhelp32Snapshot"); return; }
    PROCESSENTRY32W pe;
    memset(&pe, 0, sizeof pe);
    pe.dwSize = sizeof pe;
    int found = 0, n = 0;
    if (Process32FirstW(s, &pe)) {
        do {
            n++;
            if (pe.th32ProcessID == GetCurrentProcessId()) found = 1;
        } while (Process32NextW(s, &pe));
    }
    CloseHandle(s);
    if (!found) fail_code(r, 0, "own pid not in %d processes", n);
    else ok(r, "own pid among %d processes", n);
}

static void p_QueryFullProcessImageNameW(result_t *r)
{
    NEED(K32, OpenProcess);
    NEED(K32, QueryFullProcessImageNameW);
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, GetCurrentProcessId());
    if (!h) { fail(r, "OpenProcess"); return; }
    wchar_t buf[MAX_PATH * 2];
    DWORD n = MAX_PATH * 2;
    BOOL b = QueryFullProcessImageNameW(h, 0, buf, &n);
    CloseHandle(h);
    if (!b) { fail(r, "QueryFullProcessImageNameW"); return; }
    if (n < 12 || _wcsicmp(buf + n - 12, L"apiprobe.exe")) { fail_code(r, 0, "unexpected image name"); return; }
    ok(r, "image name ends with apiprobe.exe");
}

static void p_GetComputerNameExW(result_t *r)
{
    NEED(K32, GetComputerNameExW);
    wchar_t buf[256];
    DWORD n = 256;
    if (!GetComputerNameExW(ComputerNameDnsHostname, buf, &n) || n == 0) { fail(r, "GetComputerNameExW"); return; }
    ok(r, "%lu chars", n);
}

static void p_ExpandEnvironmentStringsW(result_t *r)
{
    NEED(K32, SetEnvironmentVariableW);
    NEED(K32, GetEnvironmentVariableW);
    NEED(K32, ExpandEnvironmentStringsW);
    wchar_t buf[512];
    if (!SetEnvironmentVariableW(L"APIPROBE_X", L"abc")) { fail(r, "SetEnvironmentVariableW"); return; }
    if (GetEnvironmentVariableW(L"APIPROBE_X", buf, 512) != 3 || wcscmp(buf, L"abc")) { fail(r, "GetEnvironmentVariableW"); return; }
    DWORD n = ExpandEnvironmentStringsW(L"%APIPROBE_X%-%SystemRoot%", buf, 512);
    if (!n || n > 512 || wcsncmp(buf, L"abc-", 4) || buf[5] != L':') { fail(r, "ExpandEnvironmentStringsW"); return; }
    ok(r, "set, get and expand agree");
}

static void p_GetUserDefaultLocaleName(result_t *r)
{
    NEED(K32, GetUserDefaultLocaleName);
    wchar_t buf[LOCALE_NAME_MAX_LENGTH];
    int n = GetUserDefaultLocaleName(buf, LOCALE_NAME_MAX_LENGTH);
    if (n <= 1) { fail(r, "GetUserDefaultLocaleName"); return; }
    char *s = NULL;
    char tmp[LOCALE_NAME_MAX_LENGTH * 2];
    WideCharToMultiByte(CP_UTF8, 0, buf, -1, tmp, sizeof tmp, NULL, NULL);
    s = tmp;
    ok(r, "%s", s);
}

static void p_GetDateFormatEx(result_t *r)
{
    NEED(K32, GetDateFormatEx);
    SYSTEMTIME st;
    memset(&st, 0, sizeof st);
    st.wYear = 2024;
    st.wMonth = 2;
    st.wDay = 29;
    wchar_t buf[128];
    int n = GetDateFormatEx(L"en-US", 0, &st, L"yyyy-MM-dd", buf, 128, NULL);
    if (n <= 0) { fail(r, "GetDateFormatEx"); return; }
    if (wcscmp(buf, L"2024-02-29")) { fail_code(r, 0, "wrong date text"); return; }
    ok(r, "2024-02-29");
}

static void p_GetTimeZoneInformation(result_t *r)
{
    NEED(K32, GetTimeZoneInformation);
    TIME_ZONE_INFORMATION tz;
    DWORD v = GetTimeZoneInformation(&tz);
    if (v == TIME_ZONE_ID_INVALID) { fail(r, "GetTimeZoneInformation"); return; }
    ok(r, "id %lu, bias %ld", v, tz.Bias);
}

static void p_GetDynamicTimeZoneInformation(result_t *r)
{
    NEED(K32, GetDynamicTimeZoneInformation);
    DYNAMIC_TIME_ZONE_INFORMATION tz;
    memset(&tz, 0, sizeof tz);
    DWORD v = GetDynamicTimeZoneInformation(&tz);
    if (v == TIME_ZONE_ID_INVALID) { fail(r, "GetDynamicTimeZoneInformation"); return; }
    if (!tz.TimeZoneKeyName[0]) { fail_code(r, 0, "empty time zone key name"); return; }
    ok(r, "id %lu", v);
}

static void p_WideCharToMultiByte(result_t *r)
{
    NEED(K32, WideCharToMultiByte);
    NEED(K32, MultiByteToWideChar);
    const wchar_t *w = L"caf\u00e9";
    char u8[16], cp[16];
    wchar_t back[16];
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, u8, sizeof u8, NULL, NULL);
    if (n != 6 || (unsigned char)u8[3] != 0xC3 || (unsigned char)u8[4] != 0xA9) { fail(r, "UTF-8 encode (%d)", n); return; }
    n = WideCharToMultiByte(1252, 0, w, -1, cp, sizeof cp, NULL, NULL);
    if (n != 5 || (unsigned char)cp[3] != 0xE9) { fail(r, "code page 1252 encode (%d)", n); return; }
    n = MultiByteToWideChar(1252, 0, cp, -1, back, 16);
    if (n != 5 || wcscmp(back, w)) { fail(r, "code page 1252 decode"); return; }
    n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, u8, -1, back, 16);
    if (n != 5 || wcscmp(back, w)) { fail(r, "UTF-8 decode"); return; }
    ok(r, "UTF-8 and 1252 round trips");
}

static void p_GetLogicalDriveStringsW(result_t *r)
{
    NEED(K32, GetLogicalDriveStringsW);
    wchar_t buf[512];
    DWORD n = GetLogicalDriveStringsW(512, buf);
    if (!n || n > 512) { fail(r, "GetLogicalDriveStringsW"); return; }
    for (wchar_t *p = buf; *p; p += wcslen(p) + 1)
        if (!_wcsicmp(p, L"C:\\")) { ok(r, "C:\\ listed"); return; }
    fail_code(r, 0, "C:\\ not listed");
}

static void p_GetDiskFreeSpaceExW(result_t *r)
{
    NEED(K32, GetDiskFreeSpaceExW);
    ULARGE_INTEGER avail, total, freeb;
    if (!GetDiskFreeSpaceExW(L"C:\\", &avail, &total, &freeb)) { fail(r, "GetDiskFreeSpaceExW"); return; }
    if (!total.QuadPart) { fail_code(r, 0, "total is 0"); return; }
    ok(r, "%llu MiB total", total.QuadPart >> 20);
}

static void p_GetVolumeInformationW(result_t *r)
{
    NEED(K32, GetVolumeInformationW);
    wchar_t fs[64];
    DWORD serial, maxlen, flags;
    if (!GetVolumeInformationW(L"C:\\", NULL, 0, &serial, &maxlen, &flags, fs, 64)) { fail(r, "GetVolumeInformationW"); return; }
    char s[64];
    WideCharToMultiByte(CP_UTF8, 0, fs, -1, s, sizeof s, NULL, NULL);
    ok(r, "file system %s", s);
}

static HANDLE open_conout(void)
{
    return CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                       OPEN_EXISTING, 0, NULL);
}

static void p_GetConsoleMode(result_t *r)
{
    NEED(K32, GetConsoleMode);
    NEED(K32, SetConsoleMode);
    HANDLE h = open_conout();
    if (h == INVALID_HANDLE_VALUE) { fail(r, "no console (CONOUT$)"); return; }
    DWORD mode = 0;
    if (!GetConsoleMode(h, &mode)) { fail(r, "GetConsoleMode"); CloseHandle(h); return; }
    if (!SetConsoleMode(h, mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING)) {
        fail(r, "SetConsoleMode(ENABLE_VIRTUAL_TERMINAL_PROCESSING)");
    } else {
        DWORD now = 0;
        GetConsoleMode(h, &now);
        SetConsoleMode(h, mode);
        if (!(now & ENABLE_VIRTUAL_TERMINAL_PROCESSING)) fail_code(r, 0, "VT flag did not stick");
        else ok(r, "mode 0x%lx, VT processing settable", mode);
    }
    CloseHandle(h);
}

static void p_GetConsoleScreenBufferInfo(result_t *r)
{
    NEED(K32, GetConsoleScreenBufferInfo);
    HANDLE h = open_conout();
    if (h == INVALID_HANDLE_VALUE) { fail(r, "no console (CONOUT$)"); return; }
    CONSOLE_SCREEN_BUFFER_INFO ci;
    if (!GetConsoleScreenBufferInfo(h, &ci)) fail(r, "GetConsoleScreenBufferInfo");
    else ok(r, "%dx%d buffer", ci.dwSize.X, ci.dwSize.Y);
    CloseHandle(h);
}

typedef void *hpcon_t;
typedef HRESULT (WINAPI *CreatePseudoConsole_t)(COORD, HANDLE, HANDLE, DWORD, hpcon_t *);
typedef HRESULT (WINAPI *ResizePseudoConsole_t)(hpcon_t, COORD);
typedef void (WINAPI *ClosePseudoConsole_t)(hpcon_t);

static ClosePseudoConsole_t g_close_pc;

static DWORD WINAPI close_pc_thread(void *p)
{
    g_close_pc((hpcon_t)p);
    return 0;
}

static void p_CreatePseudoConsole(result_t *r)
{
    NEEDT(K32, CreatePseudoConsole_t, CreatePseudoConsole);
    NEEDT(K32, ResizePseudoConsole_t, ResizePseudoConsole);
    NEEDT(K32, ClosePseudoConsole_t, ClosePseudoConsole);
    NEED(K32, InitializeProcThreadAttributeList);
    NEED(K32, UpdateProcThreadAttribute);
    NEED(K32, DeleteProcThreadAttributeList);
    g_close_pc = ClosePseudoConsole;
    HANDLE in_r, in_w, out_r, out_w;
    if (!CreatePipe(&in_r, &in_w, NULL, 0)) { fail(r, "CreatePipe"); return; }
    if (!CreatePipe(&out_r, &out_w, NULL, 0)) { fail(r, "CreatePipe"); CloseHandle(in_r); CloseHandle(in_w); return; }
    COORD sz = { 80, 25 };
    hpcon_t pc = NULL;
    HRESULT hr = CreatePseudoConsole(sz, in_r, out_w, 0, &pc);
    CloseHandle(in_r);
    CloseHandle(out_w);
    if (FAILED(hr)) { fail_code(r, (DWORD)hr, "CreatePseudoConsole hr 0x%08lx", (unsigned long)hr); CloseHandle(in_w); CloseHandle(out_r); return; }
    COORD sz2 = { 100, 30 };
    hr = ResizePseudoConsole(pc, sz2);
    if (FAILED(hr)) { fail_code(r, (DWORD)hr, "ResizePseudoConsole hr 0x%08lx", (unsigned long)hr); goto close; }

    SIZE_T alen = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &alen);
    LPPROC_THREAD_ATTRIBUTE_LIST al = HeapAlloc(GetProcessHeap(), 0, alen);
    if (!al || !InitializeProcThreadAttributeList(al, 1, 0, &alen)) { fail(r, "InitializeProcThreadAttributeList"); goto close; }
    if (!UpdateProcThreadAttribute(al, 0, 0x00020016 /* PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE */, pc, sizeof pc, NULL, NULL)) {
        fail(r, "UpdateProcThreadAttribute");
        DeleteProcThreadAttributeList(al);
        HeapFree(GetProcessHeap(), 0, al);
        goto close;
    }
    {
        STARTUPINFOEXW si;
        memset(&si, 0, sizeof si);
        si.StartupInfo.cb = sizeof si;
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES; /* NULL std handles: use the conpty */
        si.lpAttributeList = al;
        PROCESS_INFORMATION pi;
        wchar_t cmd[MAX_PATH], line[MAX_PATH + 32];
        sys32_path(L"cmd.exe", cmd, MAX_PATH);
        _snwprintf(line, MAX_PATH + 32, L"\"%ls\" /c echo hi", cmd);
        if (!CreateProcessW(cmd, line, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &si.StartupInfo, &pi)) {
            fail(r, "CreateProcessW in conpty");
        } else {
            char out[8192];
            DWORD len = 0, avail, got;
            DWORD t0 = GetTickCount();
            int found = 0;
            while (GetTickCount() - t0 < 20000 && !found) {
                if (PeekNamedPipe(out_r, NULL, 0, NULL, &avail, NULL) && avail && len < sizeof out - 1) {
                    if (ReadFile(out_r, out + len, (DWORD)(sizeof out - 1 - len) < avail ? (DWORD)(sizeof out - 1 - len) : avail, &got, NULL))
                        len += got;
                    out[len] = 0;
                    for (DWORD i = 0; i + 1 < len; i++)
                        if (out[i] == 'h' && out[i + 1] == 'i' && (i == 0 || out[i - 1] != 'o')) found = 1;
                } else {
                    Sleep(20);
                }
            }
            if (found) ok(r, "read 'hi' back through the conpty (%lu bytes)", len);
            else fail_code(r, 0, "no 'hi' within 20 s (%lu bytes)", len);
            WaitForSingleObject(pi.hProcess, found ? 1000 : 0);
            TerminateProcess(pi.hProcess, 0);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
    }
    DeleteProcThreadAttributeList(al);
    HeapFree(GetProcessHeap(), 0, al);
close:
    CloseHandle(in_w);
    {
        /* ClosePseudoConsole can block until the output pipe is drained. */
        HANDLE t = CreateThread(NULL, 0, close_pc_thread, pc, 0, NULL);
        DWORD t0 = GetTickCount();
        char buf[4096];
        DWORD avail, got;
        while (t && WaitForSingleObject(t, 10) == WAIT_TIMEOUT && GetTickCount() - t0 < 3000) {
            if (PeekNamedPipe(out_r, NULL, 0, NULL, &avail, NULL) && avail) ReadFile(out_r, buf, sizeof buf < avail ? sizeof buf : avail, &got, NULL);
        }
        if (t) CloseHandle(t);
    }
    CloseHandle(out_r);
}

static void p_AddDllDirectory(result_t *r)
{
    NEED(K32, AddDllDirectory);
    NEED(K32, RemoveDllDirectory);
    NEED(K32, LoadLibraryExW);
    wchar_t dir[MAX_PATH];
    if (!probe_tmpdir(r, "AddDllDirectory", dir, MAX_PATH)) return;
    DLL_DIRECTORY_COOKIE c = AddDllDirectory(dir);
    if (!c) { fail(r, "AddDllDirectory"); rm_tree(dir); return; }
    HMODULE h = LoadLibraryExW(L"version.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_USER_DIRS);
    if (!h) fail(r, "LoadLibraryExW(version.dll, SEARCH_SYSTEM32 | SEARCH_USER_DIRS)");
    else if (!RemoveDllDirectory(c)) fail(r, "RemoveDllDirectory");
    else ok(r, "user dir added, system32 load works, removed");
    rm_tree(dir);
}

typedef void (WINAPI *GetSystemTimePreciseAsFileTime_t)(FILETIME *);

static void p_GetSystemTimePreciseAsFileTime(result_t *r)
{
    NEEDT(K32, GetSystemTimePreciseAsFileTime_t, GetSystemTimePreciseAsFileTime);
    FILETIME a, b;
    GetSystemTimePreciseAsFileTime(&a);
    Sleep(2);
    GetSystemTimePreciseAsFileTime(&b);
    ULONGLONG x = ((ULONGLONG)a.dwHighDateTime << 32) | a.dwLowDateTime;
    ULONGLONG y = ((ULONGLONG)b.dwHighDateTime << 32) | b.dwLowDateTime;
    if (y <= x) { fail_code(r, 0, "time did not advance"); return; }
    ok(r, "advanced %llu x 100 ns", y - x);
}

static void p_QueryPerformanceCounter(result_t *r)
{
    NEED(K32, QueryPerformanceCounter);
    NEED(K32, QueryPerformanceFrequency);
    NEED(K32, GetTickCount64);
    LARGE_INTEGER f, a, b;
    if (!QueryPerformanceFrequency(&f) || !f.QuadPart) { fail(r, "QueryPerformanceFrequency"); return; }
    ULONGLONG t = GetTickCount64();
    QueryPerformanceCounter(&a);
    Sleep(5);
    QueryPerformanceCounter(&b);
    if (b.QuadPart <= a.QuadPart || !t) { fail_code(r, 0, "counter did not advance"); return; }
    ok(r, "frequency %lld", f.QuadPart);
}

const probe_t probes_kernel32[] = {
    PROBE(kernel32, GetVersionExW, "agrees with RtlGetVersion", 0, p_GetVersionExW),
    PROBE(ntdll, RtlGetVersion, "major version 10", 0, p_RtlGetVersion),
    PROBE(kernel32, GetNativeSystemInfo, "PROCESSOR_ARCHITECTURE_AMD64", 0, p_GetNativeSystemInfo),
    PROBE(kernel32, CreateFileW, "64 KiB write, seek, read back", 0, p_CreateFileW),
    PROBE(kernel32, FindFirstFileExW, "FindExInfoBasic finds the temp file", 0, p_FindFirstFileExW),
    PROBE(kernel32, GetFinalPathNameByHandleW, "returns a \\\\?\\C:\\ path", 0, p_GetFinalPathNameByHandleW),
    PROBE(kernel32, CreateHardLinkW, "the link exists", 0, p_CreateHardLinkW),
    PROBE(kernel32, CreateSymbolicLinkW, "unprivileged file symlink exists", 0, p_CreateSymbolicLinkW),
    PROBE(kernel32, ReadDirectoryChangesW, "sees a file created by a second thread within 2 s", 0, p_ReadDirectoryChangesW),
    PROBE(kernel32, CreateProcessW, "cmd /c exit 7 gives exit code 7", 0, p_CreateProcessW),
    PROBE(kernel32, CreatePipe, "anonymous pipe round trip", 0, p_CreatePipe),
    PROBE(kernel32, CreateNamedPipeW, "loopback message arrives", 0, p_CreateNamedPipeW),
    PROBE(kernel32, WaitForMultipleObjects, "thread, event and waitable timer", 0, p_WaitForMultipleObjects),
    PROBE(kernel32, VirtualProtect, "runs a generated code stub", 0, p_VirtualProtect),
    PROBE(kernel32, CreateJobObjectW, "kill-on-close ends the child", 0, p_CreateJobObjectW),
    PROBE(kernel32, CreateToolhelp32Snapshot, "sees its own PID", 0, p_CreateToolhelp32Snapshot),
    PROBE(kernel32, QueryFullProcessImageNameW, "OpenProcess on itself", 0, p_QueryFullProcessImageNameW),
    PROBE(kernel32, GetComputerNameExW, "ComputerNameDnsHostname", 0, p_GetComputerNameExW),
    PROBE(kernel32, ExpandEnvironmentStringsW, "set, get and expand variables", 0, p_ExpandEnvironmentStringsW),
    PROBE(kernel32, GetUserDefaultLocaleName, "returns a locale name", 0, p_GetUserDefaultLocaleName),
    PROBE(kernel32, GetDateFormatEx, "en-US yyyy-MM-dd", 0, p_GetDateFormatEx),
    PROBE(kernel32, GetTimeZoneInformation, "returns a zone", 0, p_GetTimeZoneInformation),
    PROBE(kernel32, GetDynamicTimeZoneInformation, "returns a zone key name", 0, p_GetDynamicTimeZoneInformation),
    PROBE(kernel32, WideCharToMultiByte, "CP_UTF8 and 1252 round trips", 0, p_WideCharToMultiByte),
    PROBE(kernel32, GetLogicalDriveStringsW, "lists C:\\", 0, p_GetLogicalDriveStringsW),
    PROBE(kernel32, GetDiskFreeSpaceExW, "C:\\ has a size", 0, p_GetDiskFreeSpaceExW),
    PROBE(kernel32, GetVolumeInformationW, "C:\\ file system name", 0, p_GetVolumeInformationW),
    PROBE(kernel32, GetConsoleMode, "CONOUT$ mode, ENABLE_VIRTUAL_TERMINAL_PROCESSING", 0, p_GetConsoleMode),
    PROBE(kernel32, GetConsoleScreenBufferInfo, "CONOUT$ buffer size", 0, p_GetConsoleScreenBufferInfo),
    PROBE(kernel32, CreatePseudoConsole, "cmd /c echo hi in an 80x25 conpty", 0, p_CreatePseudoConsole),
    PROBE(kernel32, AddDllDirectory, "LOAD_LIBRARY_SEARCH_* with a user dir", 0, p_AddDllDirectory),
    PROBE(kernel32, GetSystemTimePreciseAsFileTime, "time advances", 0, p_GetSystemTimePreciseAsFileTime),
    PROBE(kernel32, QueryPerformanceCounter, "counter advances, GetTickCount64", 0, p_QueryPerformanceCounter),
    PROBE_END
};
