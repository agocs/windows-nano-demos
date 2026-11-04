/* probes_advapi32.c - security, registry, services and event log probes. */
#include "probes.h"
#include <sddl.h>

#define ADV "advapi32"

static void p_LookupAccountSidW(result_t *r)
{
    NEED(ADV, OpenProcessToken);
    NEED(ADV, GetTokenInformation);
    NEED(ADV, LookupAccountSidW);
    HANDLE tok;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) { fail(r, "OpenProcessToken"); return; }
    union { TOKEN_USER tu; BYTE b[512]; } u;
    DWORD n = 0;
    if (!GetTokenInformation(tok, TokenUser, &u, sizeof u, &n)) { fail(r, "GetTokenInformation"); CloseHandle(tok); return; }
    CloseHandle(tok);
    wchar_t name[256], dom[256];
    DWORD cn = 256, cd = 256;
    SID_NAME_USE use;
    if (!LookupAccountSidW(NULL, u.tu.User.Sid, name, &cn, dom, &cd, &use)) { fail(r, "LookupAccountSidW"); return; }
    char a[256], b[256];
    WideCharToMultiByte(CP_UTF8, 0, dom, -1, a, sizeof a, NULL, NULL);
    WideCharToMultiByte(CP_UTF8, 0, name, -1, b, sizeof b, NULL, NULL);
    ok(r, "%s\\%s", a, b);
}

static void p_ConvertSidToStringSidW(result_t *r)
{
    NEED(ADV, CreateWellKnownSid);
    NEED(ADV, ConvertSidToStringSidW);
    BYTE sid[SECURITY_MAX_SID_SIZE];
    DWORD n = sizeof sid;
    if (!CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL, sid, &n)) { fail(r, "CreateWellKnownSid"); return; }
    wchar_t *s = NULL;
    if (!ConvertSidToStringSidW(sid, &s)) { fail(r, "ConvertSidToStringSidW"); return; }
    int good = !wcscmp(s, L"S-1-5-32-544");
    LocalFree(s);
    if (!good) fail_code(r, 0, "unexpected SID string");
    else ok(r, "S-1-5-32-544");
}

static void p_RegQueryValueExW(result_t *r)
{
    NEED(ADV, RegOpenKeyExW);
    NEED(ADV, RegQueryValueExW);
    NEED(ADV, RegCloseKey);
    HKEY k;
    LONG e = RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", 0, KEY_READ, &k);
    if (e) { fail_code(r, (DWORD)e, "RegOpenKeyExW"); return; }
    wchar_t buf[64];
    DWORD type, cb = sizeof buf;
    e = RegQueryValueExW(k, L"CurrentBuild", NULL, &type, (BYTE *)buf, &cb);
    RegCloseKey(k);
    if (e || type != REG_SZ) { fail_code(r, (DWORD)e, "RegQueryValueExW CurrentBuild"); return; }
    DWORD ma, mi, bu;
    os_version(&ma, &mi, &bu);
    if ((DWORD)wcstoul(buf, NULL, 10) != bu) { fail_code(r, 0, "CurrentBuild does not match RtlGetVersion"); return; }
    ok(r, "CurrentBuild %lu", bu);
}

static void p_RegCreateKeyExW(result_t *r)
{
    NEED(ADV, RegCreateKeyExW);
    NEED(ADV, RegSetValueExW);
    NEED(ADV, RegQueryValueExW);
    NEED(ADV, RegDeleteTreeW);
    NEED(ADV, RegCloseKey);
    HKEY k;
    LONG e = RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\apiprobe\\test", 0, NULL, 0, KEY_ALL_ACCESS, NULL, &k, NULL);
    if (e) { fail_code(r, (DWORD)e, "RegCreateKeyExW"); return; }
    DWORD v = 0x1234, back = 0, cb = sizeof back, type;
    e = RegSetValueExW(k, L"v", 0, REG_DWORD, (BYTE *)&v, sizeof v);
    if (!e) e = RegQueryValueExW(k, L"v", NULL, &type, (BYTE *)&back, &cb);
    RegCloseKey(k);
    LONG d = RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\apiprobe");
    if (e) fail_code(r, (DWORD)e, "set or query value");
    else if (back != v) fail_code(r, 0, "value differs");
    else if (d) fail_code(r, (DWORD)d, "RegDeleteTreeW");
    else ok(r, "create, set, read back, delete tree");
}

static void p_GetUserNameW(result_t *r)
{
    NEED(ADV, GetUserNameW);
    wchar_t buf[256];
    DWORD n = 256;
    if (!GetUserNameW(buf, &n)) { fail(r, "GetUserNameW"); return; }
    char s[256];
    WideCharToMultiByte(CP_UTF8, 0, buf, -1, s, sizeof s, NULL, NULL);
    ok(r, "%s", s);
}

static void p_CryptGenRandom(result_t *r)
{
    NEED(ADV, CryptAcquireContextW);
    NEED(ADV, CryptGenRandom);
    NEED(ADV, CryptReleaseContext);
    HCRYPTPROV h;
    if (!CryptAcquireContextW(&h, NULL, NULL, PROV_RSA_AES, CRYPT_VERIFYCONTEXT)) { fail(r, "CryptAcquireContextW(PROV_RSA_AES)"); return; }
    BYTE buf[32];
    memset(buf, 0, sizeof buf);
    BOOL b = CryptGenRandom(h, sizeof buf, buf);
    CryptReleaseContext(h, 0);
    int nz = 0;
    for (int i = 0; i < 32; i++) nz += buf[i] != 0;
    if (!b) fail(r, "CryptGenRandom");
    else if (nz < 8) fail_code(r, 0, "random bytes look empty");
    else ok(r, "32 random bytes");
}

static void p_EnumServicesStatusExW(result_t *r)
{
    NEED(ADV, OpenSCManagerW);
    NEED(ADV, EnumServicesStatusExW);
    NEED(ADV, CloseServiceHandle);
    SC_HANDLE m = OpenSCManagerW(NULL, NULL, SC_MANAGER_ENUMERATE_SERVICE);
    if (!m) { fail(r, "OpenSCManagerW"); return; }
    DWORD need = 0, count = 0, resume = 0;
    static BYTE buf[256 * 1024];
    BOOL b = EnumServicesStatusExW(m, SC_ENUM_PROCESS_INFO, SERVICE_WIN32, SERVICE_STATE_ALL, buf, sizeof buf, &need,
                                   &count, &resume, NULL);
    DWORD e = GetLastError();
    CloseServiceHandle(m);
    if (!b && e != ERROR_MORE_DATA) { fail_code(r, e, "EnumServicesStatusExW"); return; }
    if (!count) { fail_code(r, 0, "no services"); return; }
    ok(r, "%lu services", count);
}

static void p_ReportEventW(result_t *r)
{
    NEED(ADV, RegisterEventSourceW);
    NEED(ADV, ReportEventW);
    NEED(ADV, DeregisterEventSource);
    HANDLE h = RegisterEventSourceW(NULL, L"apiprobe");
    if (!h) { fail(r, "RegisterEventSourceW"); return; }
    LPCWSTR msg[1] = { L"apiprobe test event" };
    BOOL b = ReportEventW(h, EVENTLOG_INFORMATION_TYPE, 0, 1000, NULL, 1, 0, msg, NULL);
    DWORD e = GetLastError();
    DeregisterEventSource(h);
    if (!b) fail_code(r, e, "ReportEventW");
    else ok(r, "event reported");
}

static void p_AdjustTokenPrivileges(result_t *r)
{
    NEED(ADV, OpenProcessToken);
    NEED(ADV, LookupPrivilegeValueW);
    NEED(ADV, AdjustTokenPrivileges);
    HANDLE tok;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok)) { fail(r, "OpenProcessToken"); return; }
    TOKEN_PRIVILEGES tp;
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (!LookupPrivilegeValueW(NULL, L"SeChangeNotifyPrivilege", &tp.Privileges[0].Luid)) {
        fail(r, "LookupPrivilegeValueW");
        CloseHandle(tok);
        return;
    }
    SetLastError(0);
    BOOL b = AdjustTokenPrivileges(tok, FALSE, &tp, sizeof tp, NULL, NULL);
    DWORD e = GetLastError();
    CloseHandle(tok);
    if (!b || e != ERROR_SUCCESS) fail_code(r, e, "AdjustTokenPrivileges");
    else ok(r, "SeChangeNotifyPrivilege enabled");
}

const probe_t probes_advapi32[] = {
    PROBE(advapi32, LookupAccountSidW, "token user name (User Manager\\ContainerUser)", 0, p_LookupAccountSidW),
    PROBE(advapi32, ConvertSidToStringSidW, "BUILTIN\\Administrators is S-1-5-32-544", 0, p_ConvertSidToStringSidW),
    PROBE(advapi32, RegQueryValueExW, "HKLM CurrentBuild matches RtlGetVersion", 0, p_RegQueryValueExW),
    PROBE(advapi32, RegCreateKeyExW, "HKCU\\Software\\apiprobe create, set, delete tree", 0, p_RegCreateKeyExW),
    PROBE(advapi32, GetUserNameW, "returns a name", 0, p_GetUserNameW),
    PROBE(advapi32, CryptGenRandom, "PROV_RSA_AES random bytes", 0, p_CryptGenRandom),
    PROBE(advapi32, EnumServicesStatusExW, "at least one service", 0, p_EnumServicesStatusExW),
    PROBE(advapi32, ReportEventW, "RegisterEventSourceW and ReportEventW", 0, p_ReportEventW),
    PROBE(advapi32, AdjustTokenPrivileges, "enable SeChangeNotifyPrivilege", 0, p_AdjustTokenPrivileges),
    PROBE_END
};
