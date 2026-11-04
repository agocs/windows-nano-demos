/* probes_net.c - ws2_32, iphlpapi, dnsapi, winhttp, wininet and urlmon probes.
 *
 * Nothing here may call a ws2_32 function directly (htons included): that would
 * add ws2_32.dll to the import table. */
#include "probes.h"
#include <ws2tcpip.h>

#define WS "ws2_32"

static unsigned short be16(unsigned short v) { return (unsigned short)((v >> 8) | (v << 8)); }

typedef struct {
    __typeof__(&WSAStartup) WSAStartup;
    __typeof__(&WSACleanup) WSACleanup;
    __typeof__(&socket) socket;
    __typeof__(&bind) bind;
    __typeof__(&listen) listen;
    __typeof__(&accept) accept;
    __typeof__(&connect) connect;
    __typeof__(&send) send;
    __typeof__(&recv) recv;
    __typeof__(&closesocket) closesocket;
    __typeof__(&getsockname) getsockname;
} ws_t;

static int ws_load(result_t *r, ws_t *w)
{
#define WSN(n) if (!(w->n = need_(r, WS, #n))) return 0
    WSN(WSAStartup); WSN(WSACleanup); WSN(socket); WSN(bind); WSN(listen); WSN(accept);
    WSN(connect); WSN(send); WSN(recv); WSN(closesocket); WSN(getsockname);
#undef WSN
    WSADATA d;
    int e = w->WSAStartup(MAKEWORD(2, 2), &d);
    if (e) { fail_code(r, (DWORD)e, "WSAStartup"); return 0; }
    return 1;
}

typedef __typeof__(&WSAGetLastError) wsaerr_t;

static DWORD wsa_err(void)
{
    static wsaerr_t f;
    if (!f) f = (wsaerr_t)(void *)GetProcAddress(GetModuleHandleW(L"ws2_32.dll"), "WSAGetLastError");
    return f ? (DWORD)f() : 0;
}

static void p_tcp_loopback(result_t *r)
{
    ws_t w;
    if (!ws_load(r, &w)) return;
    SOCKET ls = w.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP), cs = INVALID_SOCKET, as = INVALID_SOCKET;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = 0x0100007F; /* 127.0.0.1 */
    int len = sizeof a;
    char buf[16] = { 0 };
    if (ls == INVALID_SOCKET) { fail_code(r, wsa_err(), "socket"); goto out; }
    if (w.bind(ls, (struct sockaddr *)&a, sizeof a) || w.listen(ls, 1) || w.getsockname(ls, (struct sockaddr *)&a, &len)) {
        fail_code(r, wsa_err(), "bind/listen");
        goto out;
    }
    cs = w.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (cs == INVALID_SOCKET || w.connect(cs, (struct sockaddr *)&a, sizeof a)) { fail_code(r, wsa_err(), "connect"); goto out; }
    as = w.accept(ls, NULL, NULL);
    if (as == INVALID_SOCKET) { fail_code(r, wsa_err(), "accept"); goto out; }
    if (w.send(cs, "echo", 4, 0) != 4 || w.recv(as, buf, sizeof buf, 0) != 4) { fail_code(r, wsa_err(), "send/recv"); goto out; }
    if (w.send(as, buf, 4, 0) != 4 || w.recv(cs, buf, sizeof buf, 0) != 4 || memcmp(buf, "echo", 4)) {
        fail_code(r, wsa_err(), "echo back");
        goto out;
    }
    ok(r, "TCP echo on 127.0.0.1:%u", be16(a.sin_port));
out:
    if (as != INVALID_SOCKET) w.closesocket(as);
    if (cs != INVALID_SOCKET) w.closesocket(cs);
    if (ls != INVALID_SOCKET) w.closesocket(ls);
    w.WSACleanup();
}

static void p_getaddrinfo(result_t *r)
{
    ws_t w;
    if (!ws_load(r, &w)) return;
    NEED(WS, getaddrinfo);
    NEED(WS, freeaddrinfo);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int e = getaddrinfo("localhost", "80", &hints, &res);
    if (e || !res) fail_code(r, (DWORD)e, "getaddrinfo(localhost)");
    else ok(r, "localhost resolved");
    if (res) freeaddrinfo(res);
    w.WSACleanup();
}

static void p_GetAddrInfoW(result_t *r)
{
    ws_t w;
    if (!ws_load(r, &w)) return;
    NEED(WS, GetAddrInfoW);
    NEED(WS, FreeAddrInfoW);
    ADDRINFOW hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    int e = GetAddrInfoW(L"github.com", L"443", &hints, &res);
    if (e || !res) fail_code(r, (DWORD)e, "GetAddrInfoW(github.com)");
    else ok(r, "github.com resolved");
    if (res) FreeAddrInfoW(res);
    w.WSACleanup();
}

static void p_WSAPoll(result_t *r)
{
    ws_t w;
    if (!ws_load(r, &w)) return;
    NEED(WS, WSAPoll);
    NEED(WS, ioctlsocket);
    SOCKET s = w.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) { fail_code(r, wsa_err(), "socket"); w.WSACleanup(); return; }
    u_long nb = 1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = 0x0100007F;
    int len = sizeof a;
    if (ioctlsocket(s, FIONBIO, &nb)) fail_code(r, wsa_err(), "ioctlsocket(FIONBIO)");
    else if (w.bind(s, (struct sockaddr *)&a, sizeof a) || w.getsockname(s, (struct sockaddr *)&a, &len)) fail_code(r, wsa_err(), "bind");
    else {
        char buf[8];
        if (w.recv(s, buf, sizeof buf, 0) != SOCKET_ERROR || wsa_err() != WSAEWOULDBLOCK) {
            fail_code(r, wsa_err(), "non-blocking recv did not return WSAEWOULDBLOCK");
        } else {
            WSAPOLLFD pf;
            pf.fd = s;
            pf.events = POLLWRNORM;
            pf.revents = 0;
            int n = WSAPoll(&pf, 1, 1000);
            if (n != 1 || !(pf.revents & POLLWRNORM)) fail_code(r, wsa_err(), "WSAPoll returned %d", n);
            else ok(r, "FIONBIO and WSAPoll(POLLWRNORM)");
        }
    }
    w.closesocket(s);
    w.WSACleanup();
}

struct sockaddr_un_ { unsigned short sun_family; char sun_path[108]; };

static void p_af_unix(result_t *r)
{
    ws_t w;
    if (!ws_load(r, &w)) return;
    wchar_t dir[MAX_PATH];
    SOCKET ls = INVALID_SOCKET, cs = INVALID_SOCKET, as = INVALID_SOCKET;
    if (!probe_tmpdir(r, "af_unix", dir, MAX_PATH)) { w.WSACleanup(); return; }
    struct sockaddr_un_ a;
    memset(&a, 0, sizeof a);
    a.sun_family = 1; /* AF_UNIX */
    char d8[MAX_PATH * 3];
    WideCharToMultiByte(CP_UTF8, 0, dir, -1, d8, sizeof d8, NULL, NULL);
    snprintf(a.sun_path, sizeof a.sun_path, "%s\\s.sock", d8);
    char buf[8] = { 0 };
    ls = w.socket(1, SOCK_STREAM, 0);
    if (ls == INVALID_SOCKET) { fail_code(r, wsa_err(), "socket(AF_UNIX)"); goto out; }
    if (w.bind(ls, (struct sockaddr *)&a, sizeof a) || w.listen(ls, 1)) { fail_code(r, wsa_err(), "bind/listen"); goto out; }
    cs = w.socket(1, SOCK_STREAM, 0);
    if (cs == INVALID_SOCKET || w.connect(cs, (struct sockaddr *)&a, sizeof a)) { fail_code(r, wsa_err(), "connect"); goto out; }
    as = w.accept(ls, NULL, NULL);
    if (as == INVALID_SOCKET) { fail_code(r, wsa_err(), "accept"); goto out; }
    if (w.send(cs, "unix", 4, 0) != 4 || w.recv(as, buf, sizeof buf, 0) != 4 || memcmp(buf, "unix", 4)) {
        fail_code(r, wsa_err(), "send/recv");
        goto out;
    }
    ok(r, "AF_UNIX stream socket under %%TEMP%%");
out:
    if (as != INVALID_SOCKET) w.closesocket(as);
    if (cs != INVALID_SOCKET) w.closesocket(cs);
    if (ls != INVALID_SOCKET) w.closesocket(ls);
    w.WSACleanup();
    rm_tree(dir);
}

typedef ULONG (WINAPI *GetAdaptersAddresses_t)(ULONG, ULONG, void *, void *, ULONG *);
typedef DWORD (WINAPI *GetExtendedTcpTable_t)(void *, DWORD *, BOOL, ULONG, int, ULONG);

static void p_GetAdaptersAddresses(result_t *r)
{
    NEEDT("iphlpapi", GetAdaptersAddresses_t, GetAdaptersAddresses);
    static BYTE buf[64 * 1024];
    ULONG n = sizeof buf;
    ULONG e = GetAdaptersAddresses(AF_UNSPEC, 0, NULL, buf, &n);
    if (e) { fail_code(r, e, "GetAdaptersAddresses"); return; }
    /* IP_ADAPTER_ADDRESSES: ULONG Length; DWORD IfIndex; then Next pointer at offset 8 */
    int count = 0;
    for (BYTE *p = buf; p; p = *(BYTE **)(p + 8)) count++;
    ok(r, "%d adapters", count);
}

static void p_GetExtendedTcpTable(result_t *r)
{
    NEEDT("iphlpapi", GetExtendedTcpTable_t, GetExtendedTcpTable);
    static BYTE buf[256 * 1024];
    DWORD n = sizeof buf;
    DWORD e = GetExtendedTcpTable(buf, &n, FALSE, AF_INET, 5 /* TCP_TABLE_OWNER_PID_ALL */, 0);
    if (e) { fail_code(r, e, "GetExtendedTcpTable"); return; }
    ok(r, "%lu IPv4 TCP entries", *(DWORD *)buf);
}

typedef LONG (WINAPI *DnsQuery_W_t)(PCWSTR, WORD, DWORD, void *, void **, void *);
typedef void (WINAPI *DnsRecordListFree_t)(void *, int);

static void p_DnsQuery_W(result_t *r)
{
    NEEDT("dnsapi", DnsQuery_W_t, DnsQuery_W);
    NEEDT("dnsapi", DnsRecordListFree_t, DnsRecordListFree);
    void *res = NULL;
    LONG e = DnsQuery_W(L"github.com", 1 /* DNS_TYPE_A */, 0, NULL, &res, NULL);
    if (e || !res) { fail_code(r, (DWORD)e, "DnsQuery_W(github.com, A)"); return; }
    DnsRecordListFree(res, 1);
    ok(r, "A record for github.com");
}

typedef void *(WINAPI *WinHttpOpen_t)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
typedef BOOL (WINAPI *WinHttpCloseHandle_t)(void *);
typedef void *(WINAPI *WinHttpConnect_t)(void *, LPCWSTR, WORD, DWORD);
typedef void *(WINAPI *WinHttpOpenRequest_t)(void *, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR *, DWORD);
typedef BOOL (WINAPI *WinHttpSendRequest_t)(void *, LPCWSTR, DWORD, void *, DWORD, DWORD, DWORD_PTR);
typedef BOOL (WINAPI *WinHttpReceiveResponse_t)(void *, void *);
typedef BOOL (WINAPI *WinHttpReadData_t)(void *, void *, DWORD, DWORD *);
typedef struct {
    DWORD dwStructSize;
    LPWSTR lpszScheme; DWORD dwSchemeLength; int nScheme;
    LPWSTR lpszHostName; DWORD dwHostNameLength; WORD nPort;
    LPWSTR lpszUserName; DWORD dwUserNameLength;
    LPWSTR lpszPassword; DWORD dwPasswordLength;
    LPWSTR lpszUrlPath; DWORD dwUrlPathLength;
    LPWSTR lpszExtraInfo; DWORD dwExtraInfoLength;
} url_components_t;
typedef BOOL (WINAPI *WinHttpCrackUrl_t)(LPCWSTR, DWORD, DWORD, url_components_t *);

static void p_WinHttpCrackUrl(result_t *r)
{
    NEEDT("winhttp", WinHttpOpen_t, WinHttpOpen);
    NEEDT("winhttp", WinHttpCloseHandle_t, WinHttpCloseHandle);
    NEEDT("winhttp", WinHttpCrackUrl_t, WinHttpCrackUrl);
    void *s = WinHttpOpen(L"apiprobe/1.0", 1 /* NO_PROXY */, NULL, NULL, 0);
    if (!s) { fail(r, "WinHttpOpen"); return; }
    WinHttpCloseHandle(s);
    url_components_t uc;
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize = sizeof uc;
    uc.dwHostNameLength = (DWORD)-1;
    uc.dwUrlPathLength = (DWORD)-1;
    if (!WinHttpCrackUrl(L"https://www.msftconnecttest.com:8443/connecttest.txt?x=1", 0, 0, &uc)) { fail(r, "WinHttpCrackUrl"); return; }
    if (uc.nPort != 8443 || uc.dwHostNameLength != 23) { fail_code(r, 0, "wrong components"); return; }
    ok(r, "WinHttpOpen and WinHttpCrackUrl");
}

static void p_WinHttpGet(result_t *r)
{
    NEEDT("winhttp", WinHttpOpen_t, WinHttpOpen);
    NEEDT("winhttp", WinHttpCloseHandle_t, WinHttpCloseHandle);
    NEEDT("winhttp", WinHttpConnect_t, WinHttpConnect);
    NEEDT("winhttp", WinHttpOpenRequest_t, WinHttpOpenRequest);
    NEEDT("winhttp", WinHttpSendRequest_t, WinHttpSendRequest);
    NEEDT("winhttp", WinHttpReceiveResponse_t, WinHttpReceiveResponse);
    NEEDT("winhttp", WinHttpReadData_t, WinHttpReadData);
    void *s = WinHttpOpen(L"apiprobe/1.0", 0 /* DEFAULT_PROXY */, NULL, NULL, 0), *c = NULL, *q = NULL;
    char buf[256] = { 0 };
    DWORD n = 0;
    if (!s) { fail(r, "WinHttpOpen"); return; }
    if (!(c = WinHttpConnect(s, L"www.msftconnecttest.com", 443, 0))) { fail(r, "WinHttpConnect"); goto out; }
    if (!(q = WinHttpOpenRequest(c, L"GET", L"/connecttest.txt", NULL, NULL, NULL, 0x00800000 /* SECURE */))) { fail(r, "WinHttpOpenRequest"); goto out; }
    if (!WinHttpSendRequest(q, NULL, 0, NULL, 0, 0, 0) || !WinHttpReceiveResponse(q, NULL)) { fail(r, "send/receive"); goto out; }
    if (!WinHttpReadData(q, buf, sizeof buf - 1, &n)) { fail(r, "WinHttpReadData"); goto out; }
    if (!strstr(buf, "Microsoft Connect Test")) fail_code(r, 0, "unexpected body");
    else ok(r, "Microsoft Connect Test");
out:
    if (q) WinHttpCloseHandle(q);
    if (c) WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
}

typedef void *(WINAPI *InternetOpenW_t)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
typedef BOOL (WINAPI *InternetCloseHandle_t)(void *);

static void p_InternetOpenW(result_t *r)
{
    NEEDT("wininet", InternetOpenW_t, InternetOpenW);
    NEEDT("wininet", InternetCloseHandle_t, InternetCloseHandle);
    void *h = InternetOpenW(L"apiprobe/1.0", 1 /* DIRECT */, NULL, NULL, 0);
    if (!h) { fail(r, "InternetOpenW"); return; }
    InternetCloseHandle(h);
    ok(r, "session opened");
}

const probe_t probes_net[] = {
    PROBE_ID("ws2_32.connect", "ws2_32", "connect", "TCP loopback echo (socket, bind, listen, connect, send, recv)", 0, p_tcp_loopback),
    PROBE(ws2_32, getaddrinfo, "localhost", 0, p_getaddrinfo),
    PROBE(ws2_32, GetAddrInfoW, "github.com", 1, p_GetAddrInfoW),
    PROBE(ws2_32, WSAPoll, "ioctlsocket(FIONBIO) and WSAPoll", 0, p_WSAPoll),
    PROBE_ID("ws2_32.AF_UNIX", "ws2_32", "socket", "AF_UNIX stream socket under %TEMP%", 0, p_af_unix),
    PROBE(iphlpapi, GetAdaptersAddresses, "at least one adapter", 0, p_GetAdaptersAddresses),
    PROBE(iphlpapi, GetExtendedTcpTable, "TCP_TABLE_OWNER_PID_ALL", 0, p_GetExtendedTcpTable),
    PROBE(dnsapi, DnsQuery_W, "github.com A record", 1, p_DnsQuery_W),
    PROBE(winhttp, WinHttpCrackUrl, "WinHttpOpen and WinHttpCrackUrl", 0, p_WinHttpCrackUrl),
    PROBE_ID("winhttp.WinHttpSendRequest", "winhttp", "WinHttpSendRequest", "GET https://www.msftconnecttest.com/connecttest.txt", 1, p_WinHttpGet),
    PROBE(wininet, InternetOpenW, "open a session", 0, p_InternetOpenW),
    PROBE(urlmon, URLDownloadToFileW, "load and resolve only", 0, NULL),
    PROBE_END
};
