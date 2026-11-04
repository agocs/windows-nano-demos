/* probes_com.c - ole32, combase and oleaut32 probes. */
#define COBJMACROS
#include "probes.h"
#include <objbase.h>
#include <oleauto.h>
#include <wbemcli.h>

#define OLE "ole32"
#define OLEAUT "oleaut32"

typedef HRESULT (WINAPI *CoInitializeEx_t)(void *, DWORD);
typedef void (WINAPI *CoUninitialize_t)(void);
typedef HRESULT (WINAPI *CoCreateGuid_t)(GUID *);
typedef int (WINAPI *StringFromGUID2_t)(REFGUID, LPOLESTR, int);
typedef HRESULT (WINAPI *CLSIDFromString_t)(LPCOLESTR, CLSID *);
typedef HRESULT (WINAPI *CoCreateInstance_t)(REFCLSID, IUnknown *, DWORD, REFIID, void **);
typedef HRESULT (WINAPI *CoInitializeSecurity_t)(PSECURITY_DESCRIPTOR, LONG, void *, void *, DWORD, DWORD, void *, DWORD, void *);
typedef HRESULT (WINAPI *CoSetProxyBlanket_t)(IUnknown *, DWORD, DWORD, OLECHAR *, DWORD, DWORD, void *, DWORD);
typedef BSTR (WINAPI *SysAllocString_t)(const OLECHAR *);
typedef void (WINAPI *SysFreeString_t)(BSTR);
typedef UINT (WINAPI *SysStringLen_t)(BSTR);
typedef HRESULT (WINAPI *VariantClear_t)(VARIANTARG *);
typedef HRESULT (WINAPI *VariantChangeType_t)(VARIANTARG *, const VARIANTARG *, USHORT, VARTYPE);
typedef SAFEARRAY *(WINAPI *SafeArrayCreate_t)(VARTYPE, UINT, SAFEARRAYBOUND *);
typedef HRESULT (WINAPI *SafeArrayDestroy_t)(SAFEARRAY *);

static const IID IID_IUnknown_ = { 0x00000000, 0x0000, 0x0000, { 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
static const CLSID CLSID_WbemLocator_ = { 0x4590F811, 0x1D3A, 0x11D0, { 0x89, 0x1F, 0x00, 0xAA, 0x00, 0x4B, 0x2E, 0x24 } };
static const IID IID_IWbemLocator_ = { 0xDC12A687, 0x737F, 0x11CF, { 0x88, 0x4D, 0x00, 0xAA, 0x00, 0x4B, 0x2E, 0x24 } };

static void p_CoCreateGuid(result_t *r)
{
    NEEDT(OLE, CoInitializeEx_t, CoInitializeEx);
    NEEDT(OLE, CoUninitialize_t, CoUninitialize);
    NEEDT(OLE, CoCreateGuid_t, CoCreateGuid);
    NEEDT(OLE, StringFromGUID2_t, StringFromGUID2);
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) { fail_code(r, (DWORD)hr, "CoInitializeEx hr 0x%08lx", (unsigned long)hr); return; }
    GUID g;
    wchar_t s[64];
    hr = CoCreateGuid(&g);
    if (FAILED(hr)) fail_code(r, (DWORD)hr, "CoCreateGuid hr 0x%08lx", (unsigned long)hr);
    else if (StringFromGUID2(&g, s, 64) != 39) fail_code(r, 0, "StringFromGUID2");
    else ok(r, "CoInitializeEx, CoCreateGuid, StringFromGUID2");
    CoUninitialize();
}

/* Creates the class (ProgID or {CLSID}) in-process or locally, then releases it. */
static void cocreate(result_t *r, const wchar_t *cls)
{
    NEEDT(OLE, CoInitializeEx_t, CoInitializeEx);
    NEEDT(OLE, CoUninitialize_t, CoUninitialize);
    NEEDT(OLE, CLSIDFromString_t, CLSIDFromString);
    NEEDT(OLE, CoCreateInstance_t, CoCreateInstance);
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) { fail_code(r, (DWORD)hr, "CoInitializeEx hr 0x%08lx", (unsigned long)hr); return; }
    CLSID c;
    hr = CLSIDFromString(cls, &c);
    if (FAILED(hr)) {
        fail_code(r, (DWORD)hr, "class not registered (CLSIDFromString hr 0x%08lx)", (unsigned long)hr);
    } else {
        IUnknown *u = NULL;
        hr = CoCreateInstance(&c, NULL, CLSCTX_INPROC_SERVER | CLSCTX_LOCAL_SERVER, &IID_IUnknown_, (void **)&u);
        if (FAILED(hr) || !u) fail_code(r, (DWORD)hr, "CoCreateInstance hr 0x%08lx", (unsigned long)hr);
        else { u->lpVtbl->Release(u); ok(r, "created"); }
    }
    CoUninitialize();
}

static void p_ShellLink(result_t *r) { cocreate(r, L"{00021401-0000-0000-C000-000000000046}"); }
static void p_TaskScheduler(result_t *r) { cocreate(r, L"Schedule.Service"); }
static void p_FileSystemObject(result_t *r) { cocreate(r, L"Scripting.FileSystemObject"); }
static void p_DOMDocument60(result_t *r) { cocreate(r, L"Msxml2.DOMDocument.6.0"); }
static void p_XMLHTTPRequest(result_t *r) { cocreate(r, L"Msxml2.XMLHTTP.6.0"); }

static void p_WbemLocator(result_t *r)
{
    NEEDT(OLE, CoInitializeEx_t, CoInitializeEx);
    NEEDT(OLE, CoUninitialize_t, CoUninitialize);
    NEEDT(OLE, CoCreateInstance_t, CoCreateInstance);
    NEEDT(OLE, CoInitializeSecurity_t, CoInitializeSecurity);
    NEEDT(OLE, CoSetProxyBlanket_t, CoSetProxyBlanket);
    NEEDT(OLEAUT, SysAllocString_t, SysAllocString);
    NEEDT(OLEAUT, SysFreeString_t, SysFreeString);
    NEEDT(OLEAUT, VariantClear_t, VariantClear);
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) { fail_code(r, (DWORD)hr, "CoInitializeEx hr 0x%08lx", (unsigned long)hr); return; }
    CoInitializeSecurity(NULL, -1, NULL, NULL, RPC_C_AUTHN_LEVEL_DEFAULT, RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE, NULL);
    IWbemLocator *loc = NULL;
    IWbemServices *svc = NULL;
    IEnumWbemClassObject *en = NULL;
    IWbemClassObject *obj = NULL;
    BSTR ns = SysAllocString(L"ROOT\\CIMV2"), wql = SysAllocString(L"WQL"),
         q = SysAllocString(L"SELECT Caption FROM Win32_OperatingSystem");
    hr = CoCreateInstance(&CLSID_WbemLocator_, NULL, CLSCTX_INPROC_SERVER, &IID_IWbemLocator_, (void **)&loc);
    if (FAILED(hr)) { fail_code(r, (DWORD)hr, "CoCreateInstance(WbemLocator) hr 0x%08lx", (unsigned long)hr); goto out; }
    hr = IWbemLocator_ConnectServer(loc, ns, NULL, NULL, NULL, 0, NULL, NULL, &svc);
    if (FAILED(hr)) { fail_code(r, (DWORD)hr, "ConnectServer(ROOT\\CIMV2) hr 0x%08lx", (unsigned long)hr); goto out; }
    CoSetProxyBlanket((IUnknown *)svc, RPC_C_AUTHN_WINNT, RPC_C_AUTHZ_NONE, NULL, RPC_C_AUTHN_LEVEL_CALL,
                      RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE);
    hr = IWbemServices_ExecQuery(svc, wql, q, WBEM_FLAG_FORWARD_ONLY | WBEM_FLAG_RETURN_IMMEDIATELY, NULL, &en);
    if (FAILED(hr)) { fail_code(r, (DWORD)hr, "ExecQuery hr 0x%08lx", (unsigned long)hr); goto out; }
    ULONG got = 0;
    hr = IEnumWbemClassObject_Next(en, 5000, 1, &obj, &got);
    if (FAILED(hr) || !got) { fail_code(r, (DWORD)hr, "no Win32_OperatingSystem row (hr 0x%08lx)", (unsigned long)hr); goto out; }
    VARIANT v;
    memset(&v, 0, sizeof v);
    hr = IWbemClassObject_Get(obj, L"Caption", 0, &v, NULL, NULL);
    if (FAILED(hr) || v.vt != VT_BSTR) fail_code(r, (DWORD)hr, "Get(Caption) hr 0x%08lx", (unsigned long)hr);
    else {
        char s[256];
        WideCharToMultiByte(CP_UTF8, 0, v.bstrVal, -1, s, sizeof s, NULL, NULL);
        ok(r, "%s", s);
    }
    VariantClear(&v);
out:
    if (obj) IWbemClassObject_Release(obj);
    if (en) IEnumWbemClassObject_Release(en);
    if (svc) IWbemServices_Release(svc);
    if (loc) IWbemLocator_Release(loc);
    SysFreeString(ns);
    SysFreeString(wql);
    SysFreeString(q);
    CoUninitialize();
}

static void p_SysAllocString(result_t *r)
{
    NEEDT(OLEAUT, SysAllocString_t, SysAllocString);
    NEEDT(OLEAUT, SysStringLen_t, SysStringLen);
    NEEDT(OLEAUT, SysFreeString_t, SysFreeString);
    BSTR b = SysAllocString(L"apiprobe");
    if (!b) { fail(r, "SysAllocString"); return; }
    UINT n = SysStringLen(b);
    SysFreeString(b);
    if (n != 8) fail_code(r, 0, "length %u", n);
    else ok(r, "BSTR of 8 chars");
}

static void p_VariantChangeType(result_t *r)
{
    NEEDT(OLEAUT, SysAllocString_t, SysAllocString);
    NEEDT(OLEAUT, VariantChangeType_t, VariantChangeType);
    NEEDT(OLEAUT, VariantClear_t, VariantClear);
    VARIANT a, b;
    memset(&a, 0, sizeof a);
    memset(&b, 0, sizeof b);
    a.vt = VT_BSTR;
    a.bstrVal = SysAllocString(L"42");
    HRESULT hr = VariantChangeType(&b, &a, 0, VT_I4);
    if (FAILED(hr)) fail_code(r, (DWORD)hr, "hr 0x%08lx", (unsigned long)hr);
    else if (b.vt != VT_I4 || b.lVal != 42) fail_code(r, 0, "wrong value");
    else ok(r, "\"42\" to VT_I4 42");
    VariantClear(&a);
    VariantClear(&b);
}

static void p_SafeArrayCreate(result_t *r)
{
    NEEDT(OLEAUT, SafeArrayCreate_t, SafeArrayCreate);
    NEEDT(OLEAUT, SafeArrayDestroy_t, SafeArrayDestroy);
    SAFEARRAYBOUND bd = { 10, 0 };
    SAFEARRAY *sa = SafeArrayCreate(VT_I4, 1, &bd);
    if (!sa) { fail(r, "SafeArrayCreate"); return; }
    SafeArrayDestroy(sa);
    ok(r, "10 element VT_I4 array");
}

const probe_t probes_com[] = {
    PROBE(ole32, CoCreateGuid, "CoInitializeEx(MTA), CoCreateGuid, StringFromGUID2", 0, p_CoCreateGuid),
    PROBE_ID("ole32.CoCreateInstance.WbemLocator", "ole32", "CoCreateInstance", "WMI SELECT Caption FROM Win32_OperatingSystem", 0, p_WbemLocator),
    PROBE_ID("ole32.CoCreateInstance.ShellLink", "ole32", "CoCreateInstance", "CLSID_ShellLink", 0, p_ShellLink),
    PROBE_ID("ole32.CoCreateInstance.TaskScheduler", "ole32", "CoCreateInstance", "Schedule.Service", 0, p_TaskScheduler),
    PROBE_ID("ole32.CoCreateInstance.FileSystemObject", "ole32", "CoCreateInstance", "Scripting.FileSystemObject (scrrun)", 0, p_FileSystemObject),
    PROBE_ID("ole32.CoCreateInstance.DOMDocument60", "ole32", "CoCreateInstance", "Msxml2.DOMDocument.6.0", 0, p_DOMDocument60),
    PROBE_ID("ole32.CoCreateInstance.XMLHTTPRequest", "ole32", "CoCreateInstance", "Msxml2.XMLHTTP.6.0", 0, p_XMLHTTPRequest),
    PROBE(combase, CoCreateInstance, "load and resolve only", 0, NULL),
    PROBE(oleaut32, SysAllocString, "BSTR length", 0, p_SysAllocString),
    PROBE(oleaut32, VariantChangeType, "VT_BSTR to VT_I4", 0, p_VariantChangeType),
    PROBE(oleaut32, SafeArrayCreate, "VT_I4 array", 0, p_SafeArrayCreate),
    PROBE_END
};
