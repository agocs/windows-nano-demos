/* probes_user32.c - user32 probes (mostly stubs in nanoserver) and gdi32. */
#include "probes.h"

#define U32 "user32"
#define G32 "gdi32"

static void p_GetSystemMetrics(result_t *r)
{
    NEED(U32, GetSystemMetrics);
    int cx = GetSystemMetrics(SM_CXSCREEN), cy = GetSystemMetrics(SM_CYSCREEN);
    ok(r, "SM_CXSCREEN %d, SM_CYSCREEN %d", cx, cy);
}

static void p_GetUserObjectInformationW(result_t *r)
{
    NEED(U32, GetProcessWindowStation);
    NEED(U32, GetUserObjectInformationW);
    HWINSTA ws = GetProcessWindowStation();
    if (!ws) { fail(r, "GetProcessWindowStation"); return; }
    USEROBJECTFLAGS f;
    DWORD n = 0;
    if (!GetUserObjectInformationW(ws, UOI_FLAGS, &f, sizeof f, &n)) { fail(r, "GetUserObjectInformationW(UOI_FLAGS)"); return; }
    ok(r, "WSF_VISIBLE=%d", (f.dwFlags & WSF_VISIBLE) ? 1 : 0);
}

static __typeof__(&DefWindowProcW) g_defwp;

static LRESULT CALLBACK msg_wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    return g_defwp(h, m, w, l);
}

static void p_CreateWindowExW(result_t *r)
{
    NEED(U32, RegisterClassExW);
    NEED(U32, CreateWindowExW);
    NEED(U32, PostMessageW);
    NEED(U32, GetMessageW);
    NEED(U32, DestroyWindow);
    NEED(U32, DefWindowProcW);
    g_defwp = DefWindowProcW;
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = msg_wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"apiprobe_msg";
    if (!RegisterClassExW(&wc)) { fail(r, "RegisterClassExW"); return; }
    HWND w = CreateWindowExW(0, L"apiprobe_msg", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, wc.hInstance, NULL);
    if (!w) { fail(r, "CreateWindowExW(HWND_MESSAGE)"); return; }
    if (!PostMessageW(w, WM_APP + 7, 11, 22)) { fail(r, "PostMessageW"); DestroyWindow(w); return; }
    MSG m;
    BOOL b = GetMessageW(&m, w, WM_APP + 7, WM_APP + 7);
    DestroyWindow(w);
    if (b <= 0) fail(r, "GetMessageW");
    else if (m.wParam != 11 || m.lParam != 22) fail_code(r, 0, "wrong message");
    else ok(r, "message-only window round trip");
}

static void p_LoadStringW(result_t *r)
{
    NEED(U32, LoadStringW);
    wchar_t buf[64];
    int n = LoadStringW(GetModuleHandleW(NULL), IDS_APIPROBE_HELLO, buf, 64);
    if (n <= 0) { fail(r, "LoadStringW"); return; }
    if (wcscmp(buf, L"apiprobe hello")) { fail_code(r, 0, "wrong string"); return; }
    ok(r, "string resource loaded");
}

static void p_CharUpperW(result_t *r)
{
    NEED(U32, CharUpperW);
    NEED(U32, wsprintfW);
    wchar_t buf[64] = L"abcé";
    CharUpperW(buf);
    if (wcscmp(buf, L"ABCÉ")) { fail_code(r, 0, "CharUpperW"); return; }
    wchar_t out[64];
    int n = wsprintfW(out, L"%s-%d", buf, 42);
    if (n != 7 || wcscmp(out, L"ABCÉ-42")) { fail_code(r, 0, "wsprintfW"); return; }
    ok(r, "CharUpperW and wsprintfW");
}

static void p_SetClipboardData(result_t *r)
{
    NEED(U32, OpenClipboard);
    NEED(U32, EmptyClipboard);
    NEED(U32, SetClipboardData);
    NEED(U32, GetClipboardData);
    NEED(U32, CloseClipboard);
    if (!OpenClipboard(NULL)) { fail(r, "OpenClipboard"); return; }
    EmptyClipboard();
    HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE, 32);
    wchar_t *p = GlobalLock(g);
    wcscpy(p, L"apiprobe");
    GlobalUnlock(g);
    if (!SetClipboardData(CF_UNICODETEXT, g)) { fail(r, "SetClipboardData"); GlobalFree(g); CloseClipboard(); return; }
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (!h) { fail(r, "GetClipboardData"); CloseClipboard(); return; }
    p = GlobalLock(h);
    int good = p && !wcscmp(p, L"apiprobe");
    GlobalUnlock(h);
    EmptyClipboard();
    CloseClipboard();
    if (!good) fail_code(r, 0, "clipboard text differs");
    else ok(r, "clipboard round trip");
}

static void p_MapVirtualKeyW(result_t *r)
{
    NEED(U32, GetKeyboardLayout);
    NEED(U32, MapVirtualKeyW);
    HKL k = GetKeyboardLayout(0);
    UINT sc = MapVirtualKeyW('A', 0 /* MAPVK_VK_TO_VSC */);
    if (sc != 0x1E) { fail_code(r, 0, "VK A maps to scan code 0x%x, layout %p", sc, (void *)k); return; }
    ok(r, "VK A is scan code 0x1E, layout %p", (void *)k);
}

static void p_CreateCompatibleBitmap(result_t *r)
{
    NEED(G32, CreateCompatibleDC);
    NEED(G32, CreateCompatibleBitmap);
    NEED(G32, SelectObject);
    NEED(G32, DeleteObject);
    NEED(G32, DeleteDC);
    HDC dc = CreateCompatibleDC(NULL);
    if (!dc) { fail(r, "CreateCompatibleDC(NULL)"); return; }
    HBITMAP bm = CreateCompatibleBitmap(dc, 16, 16);
    if (!bm) { fail(r, "CreateCompatibleBitmap"); DeleteDC(dc); return; }
    HGDIOBJ old = SelectObject(dc, bm);
    if (!old || old == HGDI_ERROR) fail(r, "SelectObject");
    else { SelectObject(dc, old); ok(r, "memory DC with a bitmap"); }
    DeleteObject(bm);
    DeleteDC(dc);
}

static void p_CreateFontIndirectW(result_t *r)
{
    NEED(G32, GetStockObject);
    NEED(G32, CreateFontIndirectW);
    NEED(G32, DeleteObject);
    if (!GetStockObject(DEFAULT_GUI_FONT)) { fail(r, "GetStockObject(DEFAULT_GUI_FONT)"); return; }
    LOGFONTW lf;
    memset(&lf, 0, sizeof lf);
    lf.lfHeight = -12;
    wcscpy(lf.lfFaceName, L"Arial");
    HFONT f = CreateFontIndirectW(&lf);
    if (!f) { fail(r, "CreateFontIndirectW"); return; }
    DeleteObject(f);
    ok(r, "stock and created fonts");
}

const probe_t probes_user32[] = {
    PROBE(user32, GetSystemMetrics, "SM_CXSCREEN", 0, p_GetSystemMetrics),
    PROBE(user32, GetUserObjectInformationW, "window station UOI_FLAGS (WSF_VISIBLE)", 0, p_GetUserObjectInformationW),
    PROBE(user32, CreateWindowExW, "HWND_MESSAGE window, PostMessageW and GetMessageW", 0, p_CreateWindowExW),
    PROBE(user32, LoadStringW, "string resource from apiprobe.exe", 0, p_LoadStringW),
    PROBE(user32, CharUpperW, "CharUpperW and wsprintfW", 0, p_CharUpperW),
    PROBE(user32, SetClipboardData, "clipboard round trip", 0, p_SetClipboardData),
    PROBE(user32, MapVirtualKeyW, "GetKeyboardLayout, VK A to scan code", 0, p_MapVirtualKeyW),
    PROBE_END
};

const probe_t probes_gdi32[] = {
    PROBE(gdi32, CreateCompatibleBitmap, "CreateCompatibleDC(NULL), bitmap, SelectObject", 0, p_CreateCompatibleBitmap),
    PROBE(gdi32, CreateFontIndirectW, "DEFAULT_GUI_FONT and CreateFontIndirectW", 0, p_CreateFontIndirectW),
    PROBE_END
};
