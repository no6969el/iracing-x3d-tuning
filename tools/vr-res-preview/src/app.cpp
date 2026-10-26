#include "renderer.h"
#include "vrmath.h"

#ifndef XR_USE_PLATFORM_WIN32
#define XR_USE_PLATFORM_WIN32
#endif
#ifndef XR_USE_GRAPHICS_API_D3D11
#define XR_USE_GRAPHICS_API_D3D11
#endif

#include <windows.h>
#include <shellapi.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <winhttp.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <wrl/client.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#pragma warning(push)
#pragma warning(disable : 4244 4267 4100 4127 4189 4505 4701 4702 4706)
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#pragma warning(pop)

using Microsoft::WRL::ComPtr;

namespace {

const float kPresets[] = {100.f, 120.f, 150.f, 200.f, 250.f, 280.f, 300.f};
const int kMsaaLevels[] = {1, 2, 4, 8};

const char* kCsvHeader =
    "utc,event,pixel_pct_requested,pixel_pct_actual,axis_scale,eye_w,eye_h,recommended_w,recommended_h,"
    "runtime_max_w,runtime_max_h,msaa,scene,ab_enabled,ab_slot,ab_a_pct,ab_b_pct,gpu_ms_avg,gpu_ms_max,"
    "cpu_ms_avg,budget_ms,frames,missed,refresh_hz,clamped\n";

struct Options {
    bool smoke = false;
    bool help = false;
    float pct = 100.f;
    int msaa = 1;
    int sky = 8;  // 0 none, 4, 8, 16, or -1 for a file
    std::wstring skyFile;
};

struct Accum {
    int frames = 0;
    int missed = 0;
    double gpuSum = 0;
    double gpuMax = 0;
    int gpuCount = 0;
    double cpuSum = 0;
};

struct TimerSlot {
    ID3D11Query* disjoint = nullptr;
    ID3D11Query* t0 = nullptr;
    ID3D11Query* t1 = nullptr;
    bool pending = false;
    bool cpuOver = false;
    double periodMs = 11.1;
};

struct EyeTarget {
    XrSwapchain swapchain = XR_NULL_HANDLE;
    std::vector<XrSwapchainImageD3D11KHR> images;
    std::vector<ID3D11RenderTargetView*> rtvs;
    std::vector<ID3D11Texture2D*> textures;
    int w = 0;
    int h = 0;
};

std::wstring ExeDir() {
    wchar_t buf[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
    std::wstring path(buf, buf + n);
    size_t slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return L".";
    return path.substr(0, slash);
}

std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
    return w;
}

void WideToUtf8(const wchar_t* w, std::string& out) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    out.assign(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w, -1, out.data(), n, nullptr, nullptr);
}

void Print(const std::string& s) { std::fputs(s.c_str(), stdout); std::fputc('\n', stdout); std::fflush(stdout); }

void Alert(const std::wstring& text) {
    std::string utf;
    WideToUtf8(text.c_str(), utf);
    Print(utf);
    MessageBoxW(nullptr, text.c_str(), L"VR Resolution Preview", MB_OK | MB_ICONERROR);
}

bool ParseArgs(Options& opt) {
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return true;
    for (int i = 1; i < argc; ++i) {
        std::wstring a = argv[i];
        auto need = [&](std::wstring& dst) {
            if (i + 1 >= argc) return false;
            dst = argv[++i];
            return true;
        };
        if (a == L"--smoke") opt.smoke = true;
        else if (a == L"--help" || a == L"-h" || a == L"/?") opt.help = true;
        else if (a == L"--pct" || a == L"--scale") {
            std::wstring v;
            if (!need(v)) return false;
            opt.pct = (float)_wtof(v.c_str());
        } else if (a == L"--msaa") {
            std::wstring v;
            if (!need(v)) return false;
            opt.msaa = _wtoi(v.c_str());
        } else if (a == L"--sky") {
            std::wstring v;
            if (!need(v)) return false;
            if (v == L"none") opt.sky = 0;
            else if (v == L"4k" || v == L"4K") opt.sky = 4;
            else if (v == L"8k" || v == L"8K") opt.sky = 8;
            else if (v == L"16k" || v == L"16K") opt.sky = 16;
            else {
                opt.sky = -1;
                opt.skyFile = v;
            }
        } else {
            LocalFree(argv);
            return false;
        }
    }
    LocalFree(argv);
    return true;
}

void PrintUsage() {
    Print(
        "vr-res-preview\n"
        "  --pct <50-400>     starting SteamVR-style pixel percent (default 100)\n"
        "  --msaa <1|2|4|8>   starting MSAA (default 1)\n"
        "  --sky <8k|16k|4k|none|file>   skybox (default 8k, downloaded on first run)\n"
        "  --smoke            offscreen shader/scene check, no headset\n");
}

const wchar_t* SkyUrl(int sky) {
    if (sky == 16)
        return L"https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/16k%2B/kloofendal_48d_partly_cloudy_puresky_16k.hdr";
    if (sky == 4)
        return L"https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/kloofendal_48d_partly_cloudy_puresky_4k.hdr";
    return L"https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/8k/kloofendal_48d_partly_cloudy_puresky_8k.hdr";
}

const wchar_t* SkyCacheName(int sky) {
    if (sky == 16) return L"kloofendal_48d_partly_cloudy_puresky_16k.hdr";
    if (sky == 4) return L"kloofendal_48d_partly_cloudy_puresky_4k.hdr";
    return L"kloofendal_48d_partly_cloudy_puresky_8k.hdr";
}

bool DownloadFile(const wchar_t* url, const std::wstring& dest, std::mutex& mu, std::string& status,
                  std::atomic<bool>& stop) {
    URL_COMPONENTS uc{};
    uc.dwStructSize = sizeof(uc);
    wchar_t host[256] = {};
    wchar_t path[2048] = {};
    wchar_t extra[1024] = {};
    uc.lpszHostName = host;
    uc.dwHostNameLength = 256;
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = 2048;
    uc.lpszExtraInfo = extra;
    uc.dwExtraInfoLength = 1024;
    if (!WinHttpCrackUrl(url, 0, 0, &uc)) return false;
    std::wstring object(path);
    object += extra;

    HINTERNET ses = WinHttpOpen(L"vr-res-preview", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
                                WINHTTP_NO_PROXY_BYPASS, 0);
    if (!ses) return false;
    WinHttpSetTimeouts(ses, 15000, 15000, 30000, 120000);
    HINTERNET con = WinHttpConnect(ses, host, uc.nPort, 0);
    if (!con) {
        WinHttpCloseHandle(ses);
        return false;
    }
    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET req = WinHttpOpenRequest(con, L"GET", object.c_str(), nullptr, WINHTTP_NO_REFERER,
                                       WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!req) {
        WinHttpCloseHandle(con);
        WinHttpCloseHandle(ses);
        return false;
    }
    DWORD policy = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
    WinHttpSetOption(req, WINHTTP_OPTION_REDIRECT_POLICY, &policy, sizeof(policy));
    bool ok = false;
    if (WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
        WinHttpReceiveResponse(req, nullptr)) {
        DWORD code = 0, codeLen = sizeof(code);
        WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                            &code, &codeLen, WINHTTP_NO_HEADER_INDEX);
        if (code >= 200 && code < 300) {
            DWORD length = 0, lengthLen = sizeof(length);
            WinHttpQueryHeaders(req, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER,
                                WINHTTP_HEADER_NAME_BY_INDEX, &length, &lengthLen, WINHTTP_NO_HEADER_INDEX);
            HANDLE file = CreateFileW(dest.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                      nullptr);
            if (file != INVALID_HANDLE_VALUE) {
                DWORD got = 0;
                DWORD total = 0;
                uint8_t buf[64 * 1024];
                ok = true;
                while (!stop.load()) {
                    DWORD n = 0;
                    if (!WinHttpReadData(req, buf, sizeof(buf), &n)) {
                        ok = false;
                        break;
                    }
                    if (n == 0) break;
                    DWORD wrote = 0;
                    if (!WriteFile(file, buf, n, &wrote, nullptr) || wrote != n) {
                        ok = false;
                        break;
                    }
                    total += n;
                    got += n;
                    if (got > 1024 * 1024) {
                        got = 0;
                        char line[96];
                        if (length > 0)
                            std::snprintf(line, sizeof(line), "Sky: downloading %u%%",
                                          (unsigned)((total * 100ull) / length));
                        else
                            std::snprintf(line, sizeof(line), "Sky: downloading %u MB", total / (1024u * 1024u));
                        std::lock_guard<std::mutex> lock(mu);
                        status = line;
                    }
                }
                if (stop.load()) ok = false;
                CloseHandle(file);
                if (!ok) DeleteFileW(dest.c_str());
            }
        }
    }
    WinHttpCloseHandle(req);
    WinHttpCloseHandle(con);
    WinHttpCloseHandle(ses);
    return ok;
}

struct KeyHold {
    int vk = 0;
    bool down = false;
    ULONGLONG next = 0;
    bool Fire(bool repeat) {
        const bool now = (GetAsyncKeyState(vk) & 0x8000) != 0;
        const ULONGLONG t = GetTickCount64();
        if (now && !down) {
            down = true;
            next = t + 400;
            return true;
        }
        if (now && down && repeat && t >= next) {
            next = t + 140;
            return true;
        }
        if (!now) down = false;
        return false;
    }
};

struct App {
    Options opt;
    Renderer renderer;
    HWND hwnd = nullptr;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain1> windowSwap;
    ID3D11RenderTargetView* windowRtv = nullptr;
    int windowW = 1280;
    int windowH = 720;

    XrInstance instance = XR_NULL_HANDLE;
    XrSystemId systemId = XR_NULL_SYSTEM_ID;
    XrSession session = XR_NULL_HANDLE;
    XrSpace space = XR_NULL_HANDLE;
    XrEnvironmentBlendMode blend = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    bool sessionRunning = false;
    bool quit = false;
    DXGI_FORMAT colorFormat = DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;

    XrActionSet actionSet = XR_NULL_HANDLE;
    XrAction actScaleUp = XR_NULL_HANDLE;
    XrAction actScaleDown = XR_NULL_HANDLE;
    XrAction actFineUp = XR_NULL_HANDLE;
    XrAction actFineDown = XR_NULL_HANDLE;
    XrAction actMsaa = XR_NULL_HANDLE;
    XrAction actFlip = XR_NULL_HANDLE;
    XrAction actScene = XR_NULL_HANDLE;
    XrAction actSave = XR_NULL_HANDLE;
    XrAction actTriggerR = XR_NULL_HANDLE;
    XrAction actTriggerL = XR_NULL_HANDLE;
    XrAction actSqueezeR = XR_NULL_HANDLE;
    XrAction actSqueezeL = XR_NULL_HANDLE;
    float trigR = 0, trigL = 0, sqR = 0, sqL = 0;
    int savePresses = 0;

    EyeTarget eyes[2];
    XrViewConfigurationView viewConfig[2] = {};
    int viewCount = 0;

    float pct = 100.f;
    int msaa = 1;
    int scene = SceneAll;
    bool ab = false;
    int abSlot = 0;
    float abA = 100.f;
    float abB = 300.f;
    bool help = false;
    bool showClamped = false;
    float actualPct = 100.f;
    float axisScale = 1.f;
    int eyeW = 0, eyeH = 0;
    int recW = 0, recH = 0, maxW = 0, maxH = 0;

    TimerSlot timers[3];
    int timerWrite = 0;
    float lastGpuMs = 0;
    float lastCpuMs = 0;
    Accum second;
    Accum setting;
    ULONGLONG lastLogTick = 0;
    double refreshHz = 90.0;
    double budgetMs = 11.111;

    FILE* csv = nullptr;
    std::mutex skyMu;
    std::string skyStatus = "Sky: procedural";
    std::thread skyThread;
    std::atomic<bool> skyStop{false};
    float* skyPixels = nullptr;
    int skyW = 0, skyH = 0;
    bool skyReady = false;

    std::wstring csvPath() const { return ExeDir() + L"\\vr-res-preview.csv"; }

    void OpenCsv() {
        csv = _wfopen(csvPath().c_str(), L"ab");
        if (!csv) {
            Print("Could not open the CSV next to the exe.");
            return;
        }
        fseek(csv, 0, SEEK_END);
        if (ftell(csv) == 0) std::fputs(kCsvHeader, csv);
        std::fflush(csv);
    }

    void WriteCsv(const char* event, const Accum& a) {
        if (!csv) return;
        SYSTEMTIME st;
        GetSystemTime(&st);
        const double gpuAvg = a.gpuCount ? a.gpuSum / a.gpuCount : 0;
        const double cpuAvg = a.frames ? a.cpuSum / a.frames : 0;
        std::fprintf(csv,
                     "%04u-%02u-%02uT%02u:%02u:%02uZ,%s,%.1f,%.2f,%.4f,%d,%d,%d,%d,%d,%d,%d,%s,%d,%d,%.1f,%.1f,"
                     "%.3f,%.3f,%.3f,%.3f,%d,%d,%.2f,%d\n",
                     st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, event, pct, actualPct, axisScale,
                     eyeW, eyeH, recW, recH, maxW, maxH, msaa, SceneName(scene), ab ? 1 : 0, ab ? abSlot : -1, abA, abB,
                     gpuAvg, a.gpuMax, cpuAvg, budgetMs, a.frames, a.missed, refreshHz, showClamped ? 1 : 0);
        std::fflush(csv);
    }

    void FlushSummary() {
        if (setting.frames > 0) WriteCsv("summary", setting);
        setting = {};
        second = {};
    }

    bool MsaaSupported(int samples) const {
        if (samples <= 1) return true;
        UINT q = 0;
        if (!device) return false;
        device->CheckMultisampleQualityLevels(DXGI_FORMAT_R8G8B8A8_UNORM, (UINT)samples, &q);
        return q > 0;
    }

    void ApplySize(bool forceSwapchain) {
        if (viewCount < 1) return;
        recW = (int)viewConfig[0].recommendedImageRectWidth;
        recH = (int)viewConfig[0].recommendedImageRectHeight;
        maxW = (int)viewConfig[0].maxImageRectWidth;
        maxH = (int)viewConfig[0].maxImageRectHeight;
        if (viewCount > 1) {
            if ((int)viewConfig[1].maxImageRectWidth < maxW) maxW = (int)viewConfig[1].maxImageRectWidth;
            if ((int)viewConfig[1].maxImageRectHeight < maxH) maxH = (int)viewConfig[1].maxImageRectHeight;
        }
        axisScale = (float)std::sqrt((double)pct / 100.0);
        uint32_t w = (uint32_t)std::lround((double)recW * (double)axisScale);
        uint32_t h = (uint32_t)std::lround((double)recH * (double)axisScale);
        if (w < 2) w = 2;
        if (h < 2) h = 2;
        showClamped = false;
        if (w > (uint32_t)maxW) {
            w = (uint32_t)maxW;
            showClamped = true;
        }
        if (h > (uint32_t)maxH) {
            h = (uint32_t)maxH;
            showClamped = true;
        }
        if (w > 16384) {
            w = 16384;
            showClamped = true;
        }
        if (h > 16384) {
            h = 16384;
            showClamped = true;
        }
        w &= ~1u;
        h &= ~1u;
        if (w < 2) w = 2;
        if (h < 2) h = 2;
        actualPct = (recW > 0 && recH > 0) ? (float)((w * (double)h) / (recW * (double)recH) * 100.0) : pct;
        const bool sizeChanged = (eyeW != (int)w || eyeH != (int)h);
        eyeW = (int)w;
        eyeH = (int)h;
        if (forceSwapchain || sizeChanged) {
            if (!RecreateSwapchains()) {
                Alert(L"Could not recreate the OpenXR swapchain at this resolution. The previous size is still in use.");
            }
        } else if (!ResizeMsaa()) {
            Alert(L"This MSAA level could not be created at the current resolution.");
        }
        char line[192];
        std::snprintf(line, sizeof(line), "scale %.0f%%  actual %.1f%%  %dx%d  MSAA %d  scene %s%s", pct, actualPct, eyeW,
                      eyeH, msaa, SceneName(scene), showClamped ? "  (clamped to runtime max)" : "");
        Print(line);
    }

    bool ResizeMsaa() {
        std::string err;
        if (renderer.Resize(eyeW, eyeH, msaa, colorFormat, err)) return true;
        Print(err);
        if (msaa != 1) {
            msaa = 1;
            return renderer.Resize(eyeW, eyeH, 1, colorFormat, err);
        }
        return false;
    }

    void DestroySwapchains() {
        for (EyeTarget& eye : eyes) {
            for (auto* rtv : eye.rtvs)
                if (rtv) rtv->Release();
            eye.rtvs.clear();
            eye.textures.clear();
            eye.images.clear();
            if (eye.swapchain) xrDestroySwapchain(eye.swapchain);
            eye.swapchain = XR_NULL_HANDLE;
        }
    }

    bool RecreateSwapchains() {
        DestroySwapchains();
        if (!ResizeMsaa()) return false;
        for (int i = 0; i < viewCount; ++i) {
            XrSwapchainCreateInfo ci{XR_TYPE_SWAPCHAIN_CREATE_INFO};
            ci.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
            ci.format = colorFormat;
            ci.sampleCount = 1;
            ci.width = (uint32_t)eyeW;
            ci.height = (uint32_t)eyeH;
            ci.faceCount = 1;
            ci.arraySize = 1;
            ci.mipCount = 1;
            XrResult result = xrCreateSwapchain(session, &ci, &eyes[i].swapchain);
            if (XR_FAILED(result)) {
                char buf[XR_MAX_RESULT_STRING_SIZE] = {};
                xrResultToString(instance, result, buf);
                Print(std::string("xrCreateSwapchain failed: ") + buf);
                return false;
            }
            uint32_t n = 0;
            xrEnumerateSwapchainImages(eyes[i].swapchain, 0, &n, nullptr);
            eyes[i].images.resize(n);
            for (auto& img : eyes[i].images) {
                img.type = XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR;
                img.next = nullptr;
            }
            result = xrEnumerateSwapchainImages(eyes[i].swapchain, n, &n,
                                               reinterpret_cast<XrSwapchainImageBaseHeader*>(eyes[i].images.data()));
            if (XR_FAILED(result)) return false;
            eyes[i].w = eyeW;
            eyes[i].h = eyeH;
            for (uint32_t k = 0; k < n; ++k) {
                ID3D11RenderTargetView* rtv = nullptr;
                if (FAILED(device->CreateRenderTargetView(eyes[i].images[k].texture, nullptr, &rtv))) return false;
                eyes[i].rtvs.push_back(rtv);
                eyes[i].textures.push_back(eyes[i].images[k].texture);
            }
        }
        return true;
    }

    void SetPct(float next) {
        next = Clampf(next, 50.f, 400.f);
        if (std::fabs(next - pct) < 0.05f) return;
        FlushSummary();
        pct = next;
        if (ab) {
            if (abSlot == 0) abA = pct;
            else abB = pct;
        }
        if (sessionRunning) ApplySize(false);
    }

    void StepPreset(int dir) {
        if (dir > 0) {
            for (float p : kPresets)
                if (p > pct + 0.1f) {
                    SetPct(p);
                    return;
                }
        } else {
            for (int i = (int)(sizeof(kPresets) / sizeof(kPresets[0])) - 1; i >= 0; --i) {
                if (kPresets[i] < pct - 0.1f) {
                    SetPct(kPresets[i]);
                    return;
                }
            }
        }
    }

    void CycleMsaa() {
        const int n = (int)(sizeof(kMsaaLevels) / sizeof(kMsaaLevels[0]));
        for (int step = 1; step <= n; ++step) {
            int idx = 0;
            for (int i = 0; i < n; ++i)
                if (kMsaaLevels[i] == msaa) idx = i;
            int next = kMsaaLevels[(idx + step) % n];
            if (!MsaaSupported(next)) continue;
            FlushSummary();
            msaa = next;
            if (sessionRunning) ApplySize(false);
            return;
        }
    }

    void CycleScene() {
        FlushSummary();
        scene = (scene + 1) % SceneCount;
        char line[64];
        std::snprintf(line, sizeof(line), "scene %s", SceneName(scene));
        Print(line);
    }

    void SaveSlot(int slot) {
        if (slot == 0) abA = pct;
        else abB = pct;
        char line[64];
        std::snprintf(line, sizeof(line), "saved %s = %.0f%%", slot == 0 ? "A" : "B", pct);
        Print(line);
    }

    void FlipAb() {
        FlushSummary();
        ab = true;
        abSlot ^= 1;
        pct = abSlot ? abB : abA;
        if (sessionRunning) ApplySize(false);
    }

    bool BoolPressed(XrAction action) {
        if (!action || !session) return false;
        XrActionStateGetInfo gi{XR_TYPE_ACTION_STATE_GET_INFO};
        gi.action = action;
        XrActionStateBoolean state{XR_TYPE_ACTION_STATE_BOOLEAN};
        if (XR_FAILED(xrGetActionStateBoolean(session, &gi, &state))) return false;
        return state.isActive && state.changedSinceLastSync && state.currentState;
    }

    bool FloatPressed(XrAction action, float& was) {
        if (!action || !session) return false;
        XrActionStateGetInfo gi{XR_TYPE_ACTION_STATE_GET_INFO};
        gi.action = action;
        XrActionStateFloat state{XR_TYPE_ACTION_STATE_FLOAT};
        if (XR_FAILED(xrGetActionStateFloat(session, &gi, &state)) || !state.isActive) return false;
        const bool edge = state.currentState > 0.65f && was <= 0.65f;
        was = state.currentState;
        return edge;
    }

    void PollInput() {
        bool up = false, down = false, fineUp = false, fineDown = false, msaaPress = false, flip = false, scenePress = false,
             save = false;
        if (sessionRunning && actionSet) {
            XrActiveActionSet active{actionSet, XR_NULL_PATH};
            XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};
            sync.countActiveActionSets = 1;
            sync.activeActionSets = &active;
            xrSyncActions(session, &sync);
            up = BoolPressed(actScaleUp) || FloatPressed(actTriggerR, trigR);
            down = BoolPressed(actScaleDown) || FloatPressed(actTriggerL, trigL);
            fineUp = BoolPressed(actFineUp) || FloatPressed(actSqueezeR, sqR);
            fineDown = BoolPressed(actFineDown) || FloatPressed(actSqueezeL, sqL);
            msaaPress = BoolPressed(actMsaa);
            flip = BoolPressed(actFlip);
            scenePress = BoolPressed(actScene);
            save = BoolPressed(actSave);
        }
        static KeyHold kNext{VK_OEM_6}, kPrev{VK_OEM_4}, kRight{VK_RIGHT}, kLeft{VK_LEFT};
        static KeyHold kDot{VK_OEM_PERIOD}, kComma{VK_OEM_COMMA}, kPlus{VK_OEM_PLUS}, kMinus{VK_OEM_MINUS};
        static KeyHold kM{'M'}, kSpace{VK_SPACE}, kV{'V'}, kTab{VK_TAB}, kH{'H'}, kEsc{VK_ESCAPE};
        static KeyHold kF5{VK_F5}, kF6{VK_F6};
        static KeyHold kNum[7] = {{'1'}, {'2'}, {'3'}, {'4'}, {'5'}, {'6'}, {'7'}};
        if (kNext.Fire(true) || kRight.Fire(true)) up = true;
        if (kPrev.Fire(true) || kLeft.Fire(true)) down = true;
        if (kDot.Fire(true) || kPlus.Fire(true)) fineUp = true;
        if (kComma.Fire(true) || kMinus.Fire(true)) fineDown = true;
        if (kM.Fire(false)) msaaPress = true;
        if (kSpace.Fire(false)) flip = true;
        if (kV.Fire(false) || kTab.Fire(false)) scenePress = true;
        if (kF5.Fire(false)) SaveSlot(0);
        if (kF6.Fire(false)) SaveSlot(1);
        if (kH.Fire(false)) help = !help;
        if (kEsc.Fire(false)) quit = true;
        for (int i = 0; i < 7; ++i)
            if (kNum[i].Fire(false)) SetPct(kPresets[i]);
        if (up) StepPreset(+1);
        if (down) StepPreset(-1);
        if (fineUp) SetPct(pct + 5.f);
        if (fineDown) SetPct(pct - 5.f);
        if (msaaPress) CycleMsaa();
        if (flip) FlipAb();
        if (scenePress) CycleScene();
        if (save) {
            SaveSlot(savePresses & 1);
            savePresses++;
        }
    }

    void PollEvents() {
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
        while (instance && xrPollEvent(instance, &event) == XR_SUCCESS) {
            if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                auto* e = reinterpret_cast<XrEventDataSessionStateChanged*>(&event);
                switch (e->state) {
                    case XR_SESSION_STATE_READY: {
                        XrSessionBeginInfo bi{XR_TYPE_SESSION_BEGIN_INFO};
                        bi.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                        if (XR_SUCCEEDED(xrBeginSession(session, &bi))) {
                            sessionRunning = true;
                            RefreshViewConfig();
                            ApplySize(true);
                            Print("Session running. Leave this app at 100% in SteamVR; the in-app percent is the scale.");
                        }
                        break;
                    }
                    case XR_SESSION_STATE_STOPPING:
                        FlushSummary();
                        DestroySwapchains();
                        xrEndSession(session);
                        sessionRunning = false;
                        break;
                    case XR_SESSION_STATE_EXITING:
                    case XR_SESSION_STATE_LOSS_PENDING:
                        quit = true;
                        break;
                    default:
                        break;
                }
            } else if (event.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING) {
                quit = true;
            }
            event.type = XR_TYPE_EVENT_DATA_BUFFER;
        }
    }

    void RefreshViewConfig() {
        uint32_t n = 0;
        xrEnumerateViewConfigurationViews(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &n, nullptr);
        if (n > 2) n = 2;
        for (uint32_t i = 0; i < n; ++i) {
            viewConfig[i] = {XR_TYPE_VIEW_CONFIGURATION_VIEW};
        }
        xrEnumerateViewConfigurationViews(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, n, &n,
                                          viewConfig);
        viewCount = (int)n;
    }

    void ConsumeSky() {
        float* pixels = nullptr;
        int w = 0, h = 0;
        std::string status;
        {
            std::lock_guard<std::mutex> lock(skyMu);
            status = skyStatus;
            if (skyReady && skyPixels) {
                pixels = skyPixels;
                w = skyW;
                h = skyH;
                skyPixels = nullptr;
                skyReady = false;
            }
        }
        if (pixels) {
            std::string err;
            Print("Uploading skybox...");
            if (renderer.UploadSky(pixels, w, h, err)) {
                std::lock_guard<std::mutex> lock(skyMu);
                skyStatus = (opt.sky == 16) ? "Sky: Poly Haven 16K CC0" : (opt.sky == 4) ? "Sky: Poly Haven 4K CC0"
                                                                                          : "Sky: Poly Haven 8K CC0";
            } else {
                std::lock_guard<std::mutex> lock(skyMu);
                skyStatus = "Sky: procedural (upload failed)";
                Print(err);
            }
            stbi_image_free(pixels);
        } else {
            std::lock_guard<std::mutex> lock(skyMu);
            skyStatus = status;
        }
    }

    void StartSky() {
        if (opt.sky == 0 && opt.skyFile.empty()) {
            skyStatus = "Sky: procedural";
            return;
        }
        skyThread = std::thread([this] { SkyWorker(); });
    }

    void SkyWorker() {
        std::wstring path = opt.skyFile;
        if (opt.sky > 0) {
            std::wstring dir = ExeDir() + L"\\cache";
            CreateDirectoryW(dir.c_str(), nullptr);
            path = dir + L"\\" + SkyCacheName(opt.sky);
            WIN32_FILE_ATTRIBUTE_DATA info{};
            const bool exists = GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info) &&
                                ((info.nFileSizeHigh > 0) || info.nFileSizeLow > 1000000);
            if (!exists) {
                {
                    std::lock_guard<std::mutex> lock(skyMu);
                    skyStatus = "Sky: downloading Poly Haven HDRI";
                }
                std::wstring partial = path + L".partial";
                if (!DownloadFile(SkyUrl(opt.sky), partial, skyMu, skyStatus, skyStop)) {
                    std::lock_guard<std::mutex> lock(skyMu);
                    skyStatus = skyStop.load() ? "Sky: procedural" : "Sky: procedural (download failed)";
                    return;
                }
                MoveFileExW(partial.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
            }
        }
        if (skyStop.load() || path.empty()) return;
        {
            std::lock_guard<std::mutex> lock(skyMu);
            skyStatus = "Sky: decoding HDRI";
        }
        FILE* file = _wfopen(path.c_str(), L"rb");
        if (!file) {
            std::lock_guard<std::mutex> lock(skyMu);
            skyStatus = "Sky: procedural (file missing)";
            return;
        }
        int w = 0, h = 0, n = 0;
        float* data = stbi_loadf_from_file(file, &w, &h, &n, 4);
        std::fclose(file);
        if (!data) {
            std::lock_guard<std::mutex> lock(skyMu);
            skyStatus = "Sky: procedural (decode failed)";
            return;
        }
        std::lock_guard<std::mutex> lock(skyMu);
        skyPixels = data;
        skyW = w;
        skyH = h;
        skyReady = true;
        skyStatus = "Sky: ready to upload";
    }

    bool Suggest(const char* profile, const std::vector<std::pair<XrAction, const char*>>& binds) {
        XrPath profilePath = XR_NULL_PATH;
        if (XR_FAILED(xrStringToPath(instance, profile, &profilePath))) return false;
        std::vector<XrActionSuggestedBinding> list;
        list.reserve(binds.size());
        for (auto& b : binds) {
            XrPath path = XR_NULL_PATH;
            if (XR_FAILED(xrStringToPath(instance, b.second, &path))) return false;
            list.push_back({b.first, path});
        }
        XrInteractionProfileSuggestedBinding info{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
        info.interactionProfile = profilePath;
        info.countSuggestedBindings = (uint32_t)list.size();
        info.suggestedBindings = list.data();
        return XR_SUCCEEDED(xrSuggestInteractionProfileBindings(instance, &info));
    }

    XrAction MakeAction(const char* name, XrActionType type) {
        XrActionCreateInfo ci{XR_TYPE_ACTION_CREATE_INFO};
        std::snprintf(ci.actionName, sizeof(ci.actionName), "%s", name);
        std::snprintf(ci.localizedActionName, sizeof(ci.localizedActionName), "%s", name);
        ci.actionType = type;
        XrAction action = XR_NULL_HANDLE;
        xrCreateAction(actionSet, &ci, &action);
        return action;
    }

    bool SetupActions() {
        XrActionSetCreateInfo si{XR_TYPE_ACTION_SET_CREATE_INFO};
        std::snprintf(si.actionSetName, sizeof(si.actionSetName), "controls");
        std::snprintf(si.localizedActionSetName, sizeof(si.localizedActionSetName), "Controls");
        if (XR_FAILED(xrCreateActionSet(instance, &si, &actionSet))) return false;
        actScaleUp = MakeAction("scale_up", XR_ACTION_TYPE_BOOLEAN_INPUT);
        actScaleDown = MakeAction("scale_down", XR_ACTION_TYPE_BOOLEAN_INPUT);
        actFineUp = MakeAction("fine_up", XR_ACTION_TYPE_BOOLEAN_INPUT);
        actFineDown = MakeAction("fine_down", XR_ACTION_TYPE_BOOLEAN_INPUT);
        actMsaa = MakeAction("msaa", XR_ACTION_TYPE_BOOLEAN_INPUT);
        actFlip = MakeAction("flip_ab", XR_ACTION_TYPE_BOOLEAN_INPUT);
        actScene = MakeAction("scene", XR_ACTION_TYPE_BOOLEAN_INPUT);
        actSave = MakeAction("save_ab", XR_ACTION_TYPE_BOOLEAN_INPUT);
        actTriggerR = MakeAction("trigger_r", XR_ACTION_TYPE_FLOAT_INPUT);
        actTriggerL = MakeAction("trigger_l", XR_ACTION_TYPE_FLOAT_INPUT);
        actSqueezeR = MakeAction("squeeze_r", XR_ACTION_TYPE_FLOAT_INPUT);
        actSqueezeL = MakeAction("squeeze_l", XR_ACTION_TYPE_FLOAT_INPUT);

        Suggest("/interaction_profiles/valve/index_controller",
                {{actTriggerR, "/user/hand/right/input/trigger/value"},
                 {actTriggerL, "/user/hand/left/input/trigger/value"},
                 {actSqueezeR, "/user/hand/right/input/squeeze/value"},
                 {actSqueezeL, "/user/hand/left/input/squeeze/value"},
                 {actMsaa, "/user/hand/right/input/a/click"},
                 {actFlip, "/user/hand/right/input/b/click"},
                 {actScene, "/user/hand/left/input/thumbstick/click"},
                 {actSave, "/user/hand/left/input/a/click"}});
        Suggest("/interaction_profiles/oculus/touch_controller",
                {{actTriggerR, "/user/hand/right/input/trigger/value"},
                 {actTriggerL, "/user/hand/left/input/trigger/value"},
                 {actSqueezeR, "/user/hand/right/input/squeeze/value"},
                 {actSqueezeL, "/user/hand/left/input/squeeze/value"},
                 {actMsaa, "/user/hand/right/input/a/click"},
                 {actFlip, "/user/hand/right/input/b/click"},
                 {actScene, "/user/hand/left/input/y/click"},
                 {actSave, "/user/hand/left/input/x/click"}});
        Suggest("/interaction_profiles/htc/vive_controller",
                {{actScaleUp, "/user/hand/right/input/trigger/click"},
                 {actScaleDown, "/user/hand/left/input/trigger/click"},
                 {actFineUp, "/user/hand/right/input/squeeze/click"},
                 {actFineDown, "/user/hand/left/input/squeeze/click"},
                 {actMsaa, "/user/hand/left/input/menu/click"},
                 {actFlip, "/user/hand/right/input/trackpad/click"},
                 {actScene, "/user/hand/left/input/trackpad/click"}});
        Suggest("/interaction_profiles/microsoft/motion_controller",
                {{actScaleUp, "/user/hand/right/input/trigger/click"},
                 {actScaleDown, "/user/hand/left/input/trigger/click"},
                 {actFineUp, "/user/hand/right/input/squeeze/click"},
                 {actFineDown, "/user/hand/left/input/squeeze/click"},
                 {actMsaa, "/user/hand/left/input/menu/click"},
                 {actFlip, "/user/hand/right/input/thumbstick/click"},
                 {actScene, "/user/hand/left/input/thumbstick/click"}});
        Suggest("/interaction_profiles/khr/simple_controller",
                {{actScaleUp, "/user/hand/right/input/select/click"},
                 {actScaleDown, "/user/hand/left/input/select/click"},
                 {actMsaa, "/user/hand/right/input/menu/click"},
                 {actScene, "/user/hand/left/input/menu/click"}});

        XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
        attach.countActionSets = 1;
        attach.actionSets = &actionSet;
        return XR_SUCCEEDED(xrAttachSessionActionSets(session, &attach));
    }

    bool PickFormat() {
        uint32_t n = 0;
        xrEnumerateSwapchainFormats(session, 0, &n, nullptr);
        std::vector<int64_t> formats(n);
        if (n) xrEnumerateSwapchainFormats(session, n, &n, formats.data());
        const int64_t prefer[] = {DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
                                  DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM};
        for (int64_t want : prefer) {
            for (int64_t have : formats)
                if (have == want) {
                    colorFormat = (DXGI_FORMAT)want;
                    return true;
                }
        }
        if (!formats.empty()) {
            colorFormat = (DXGI_FORMAT)formats[0];
            return true;
        }
        return false;
    }

    bool CreateXrDevice() {
        uint32_t extCount = 0;
        xrEnumerateInstanceExtensionProperties(nullptr, 0, &extCount, nullptr);
        std::vector<XrExtensionProperties> exts(extCount);
        for (auto& e : exts) e.type = XR_TYPE_EXTENSION_PROPERTIES;
        xrEnumerateInstanceExtensionProperties(nullptr, extCount, &extCount, exts.data());
        bool haveD3d = false;
        for (auto& e : exts)
            if (std::strcmp(e.extensionName, XR_KHR_D3D11_ENABLE_EXTENSION_NAME) == 0) haveD3d = true;
        if (!haveD3d) {
            Alert(L"The active OpenXR runtime does not expose D3D11. Start SteamVR and set it as the OpenXR runtime.");
            return false;
        }
        const char* enabled[] = {XR_KHR_D3D11_ENABLE_EXTENSION_NAME};
        XrInstanceCreateInfo ici{XR_TYPE_INSTANCE_CREATE_INFO};
        std::snprintf(ici.applicationInfo.applicationName, sizeof(ici.applicationInfo.applicationName),
                      "VR Resolution Preview");
        ici.applicationInfo.applicationVersion = 1;
        std::snprintf(ici.applicationInfo.engineName, sizeof(ici.applicationInfo.engineName), "vr-res-preview");
        ici.applicationInfo.engineVersion = 1;
        ici.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;
        ici.enabledExtensionCount = 1;
        ici.enabledExtensionNames = enabled;
        XrResult result = xrCreateInstance(&ici, &instance);
        if (XR_FAILED(result)) {
            Alert(L"OpenXR did not start. Start SteamVR, set it as the active OpenXR runtime, and run this again.");
            return false;
        }
        XrSystemGetInfo sgi{XR_TYPE_SYSTEM_GET_INFO};
        sgi.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
        result = xrGetSystem(instance, &sgi, &systemId);
        if (XR_FAILED(result)) {
            Alert(L"No headset is visible to OpenXR. Put the headset on, or wake it, with SteamVR already running.");
            return false;
        }
        PFN_xrGetD3D11GraphicsRequirementsKHR getReq = nullptr;
        xrGetInstanceProcAddr(instance, "xrGetD3D11GraphicsRequirementsKHR", (PFN_xrVoidFunction*)&getReq);
        if (!getReq) {
            Alert(L"OpenXR did not provide the D3D11 graphics requirement function.");
            return false;
        }
        XrGraphicsRequirementsD3D11KHR req{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
        if (XR_FAILED(getReq(instance, systemId, &req))) {
            Alert(L"Could not read the OpenXR graphics adapter.");
            return false;
        }
        ComPtr<IDXGIFactory1> factory;
        if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return false;
        ComPtr<IDXGIAdapter1> adapter;
        for (UINT i = 0;; ++i) {
            ComPtr<IDXGIAdapter1> candidate;
            if (factory->EnumAdapters1(i, &candidate) == DXGI_ERROR_NOT_FOUND) break;
            DXGI_ADAPTER_DESC1 desc{};
            candidate->GetDesc1(&desc);
            if (std::memcmp(&desc.AdapterLuid, &req.adapterLuid, sizeof(LUID)) == 0) {
                adapter = candidate;
                break;
            }
        }
        if (!adapter) {
            Alert(L"The OpenXR runtime's GPU does not match a DXGI adapter.");
            return false;
        }
        const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
        D3D_FEATURE_LEVEL got = D3D_FEATURE_LEVEL_11_0;
        HRESULT hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                       levels, 2, D3D11_SDK_VERSION, &device, &got, &context);
        if (FAILED(hr)) {
            Alert(L"D3D11 device creation failed on the OpenXR adapter.");
            return false;
        }
        if (got < req.minFeatureLevel) {
            Alert(L"The GPU feature level is below what the OpenXR runtime requires.");
            return false;
        }
        XrGraphicsBindingD3D11KHR binding{XR_TYPE_GRAPHICS_BINDING_D3D11_KHR};
        binding.device = device.Get();
        XrSessionCreateInfo sci{XR_TYPE_SESSION_CREATE_INFO};
        sci.next = &binding;
        sci.systemId = systemId;
        if (XR_FAILED(xrCreateSession(instance, &sci, &session))) {
            Alert(L"OpenXR session creation failed.");
            return false;
        }
        XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
        spaceInfo.poseInReferenceSpace.orientation.w = 1.f;
        if (XR_FAILED(xrCreateReferenceSpace(session, &spaceInfo, &space))) {
            spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
            if (XR_FAILED(xrCreateReferenceSpace(session, &spaceInfo, &space))) {
                Alert(L"Could not create an OpenXR reference space.");
                return false;
            }
        }
        uint32_t blendCount = 0;
        xrEnumerateEnvironmentBlendModes(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &blendCount,
                                         nullptr);
        std::vector<XrEnvironmentBlendMode> blends(blendCount);
        if (blendCount)
            xrEnumerateEnvironmentBlendModes(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, blendCount,
                                            &blendCount, blends.data());
        blend = blends.empty() ? XR_ENVIRONMENT_BLEND_MODE_OPAQUE : blends[0];
        for (auto mode : blends)
            if (mode == XR_ENVIRONMENT_BLEND_MODE_OPAQUE) blend = mode;
        if (!PickFormat()) {
            Alert(L"The runtime did not offer a color swapchain format.");
            return false;
        }
        if (!SetupActions()) Print("Controller actions were not attached. Keyboard still works.");
        std::string err;
        if (!renderer.Init(device.Get(), context.Get(), err)) {
            Alert(Utf8ToWide(err));
            return false;
        }
        for (int i = 0; i < 3; ++i) {
            D3D11_QUERY_DESC qd{D3D11_QUERY_TIMESTAMP_DISJOINT, 0};
            device->CreateQuery(&qd, &timers[i].disjoint);
            qd.Query = D3D11_QUERY_TIMESTAMP;
            device->CreateQuery(&qd, &timers[i].t0);
            device->CreateQuery(&qd, &timers[i].t1);
        }
        RefreshViewConfig();
        return viewCount > 0;
    }

    bool CreateMirror() {
        ComPtr<IDXGIDevice> dxgi;
        if (FAILED(device->QueryInterface(IID_PPV_ARGS(&dxgi)))) return false;
        ComPtr<IDXGIAdapter> adapter;
        if (FAILED(dxgi->GetAdapter(&adapter))) return false;
        ComPtr<IDXGIFactory2> factory;
        if (FAILED(adapter->GetParent(IID_PPV_ARGS(&factory)))) return false;
        DXGI_SWAP_CHAIN_DESC1 sd{};
        sd.Width = (UINT)windowW;
        sd.Height = (UINT)windowH;
        sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        sd.SampleDesc.Count = 1;
        sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        sd.BufferCount = 2;
        sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        sd.Scaling = DXGI_SCALING_STRETCH;
        sd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        if (FAILED(factory->CreateSwapChainForHwnd(device.Get(), hwnd, &sd, nullptr, nullptr, &windowSwap))) return false;
        factory->MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER);
        ComPtr<ID3D11Texture2D> back;
        windowSwap->GetBuffer(0, IID_PPV_ARGS(&back));
        return SUCCEEDED(device->CreateRenderTargetView(back.Get(), nullptr, &windowRtv));
    }

    void ReadTimers() {
        for (int n = 0; n < 3; ++n) {
            TimerSlot& slot = timers[n];
            if (!slot.pending || !slot.disjoint) continue;
            D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj{};
            if (context->GetData(slot.disjoint, &dj, sizeof(dj), 0) != S_OK) continue;
            UINT64 a = 0, b = 0;
            if (context->GetData(slot.t0, &a, sizeof(a), 0) != S_OK) continue;
            if (context->GetData(slot.t1, &b, sizeof(b), 0) != S_OK) continue;
            slot.pending = false;
            if (dj.Disjoint || dj.Frequency == 0 || b < a) {
                if (slot.cpuOver) {
                    second.missed++;
                    setting.missed++;
                }
                continue;
            }
            const double ms = double(b - a) / double(dj.Frequency) * 1000.0;
            lastGpuMs = (float)ms;
            auto addGpu = [&](Accum& a) {
                a.gpuSum += ms;
                a.gpuCount++;
                if (ms > a.gpuMax) a.gpuMax = ms;
            };
            addGpu(second);
            addGpu(setting);
            if (slot.cpuOver || ms > slot.periodMs) {
                second.missed++;
                setting.missed++;
            }
        }
    }

    void RenderFrame() {
        XrFrameWaitInfo waitInfo{XR_TYPE_FRAME_WAIT_INFO};
        XrFrameState frame{XR_TYPE_FRAME_STATE};
        if (XR_FAILED(xrWaitFrame(session, &waitInfo, &frame))) {
            quit = true;
            return;
        }
        const double periodMs = frame.predictedDisplayPeriod > 0 ? frame.predictedDisplayPeriod / 1.0e6 : budgetMs;
        if (periodMs > 1.0 && periodMs < 100.0) {
            budgetMs = periodMs;
            refreshHz = 1000.0 / periodMs;
        }
        XrFrameBeginInfo begin{XR_TYPE_FRAME_BEGIN_INFO};
        if (XR_FAILED(xrBeginFrame(session, &begin))) {
            quit = true;
            return;
        }
        const ULONGLONG t0 = GetTickCount64();
        XrCompositionLayerProjectionView proj[2]{};
        bool rendered = false;
        std::string skyCopy;
        {
            std::lock_guard<std::mutex> lock(skyMu);
            skyCopy = skyStatus;
        }
        if (frame.shouldRender && eyes[0].swapchain) {
            XrView views[2]{};
            views[0].type = views[1].type = XR_TYPE_VIEW;
            uint32_t count = (uint32_t)viewCount;
            XrViewState viewState{XR_TYPE_VIEW_STATE};
            XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO};
            locate.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
            locate.displayTime = frame.predictedDisplayTime;
            locate.space = space;
            if (XR_SUCCEEDED(xrLocateViews(session, &locate, &viewState, count, &count, views)) && count > 0) {
                TimerSlot& slot = timers[timerWrite];
                const bool timeThis = slot.disjoint && !slot.pending;
                if (timeThis) {
                    slot.cpuOver = false;
                    context->Begin(slot.disjoint);
                    context->End(slot.t0);
                }
                int eyesDrawn = 0;
                bool mirror = false;
                float mirrorVp[16]{};
                float mirrorEye[3]{};
                float mirrorRight[3]{};
                float mirrorUp[3]{};
                float mirrorFwd[3]{};
                HudInfo mirrorHud{};
                for (uint32_t i = 0; i < count; ++i) {
                    XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
                    uint32_t index = 0;
                    if (XR_FAILED(xrAcquireSwapchainImage(eyes[i].swapchain, &acquire, &index))) continue;
                    XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
                    wait.timeout = XR_INFINITE_DURATION;
                    xrWaitSwapchainImage(eyes[i].swapchain, &wait);
                    float pose[16], view[16], projM[16], vp[16];
                    const XrPosef& p = views[i].pose;
                    MatFromPose(pose, p.position.x, p.position.y, p.position.z, p.orientation.x, p.orientation.y,
                                p.orientation.z, p.orientation.w);
                    MatInvertRigid(view, pose);
                    MatProjectionD3D(projM, std::tan(views[i].fov.angleLeft), std::tan(views[i].fov.angleRight),
                                     std::tan(views[i].fov.angleUp), std::tan(views[i].fov.angleDown), 0.05f, 800.f);
                    MatMul(vp, projM, view);
                    const float eye[3] = {p.position.x, p.position.y, p.position.z};
                    const float right[3] = {pose[0], pose[1], pose[2]};
                    const float up[3] = {pose[4], pose[5], pose[6]};
                    const float forward[3] = {-pose[8], -pose[9], -pose[10]};
                    HudInfo hud = MakeHud(skyCopy);
                    if (index < eyes[i].rtvs.size())
                        renderer.RenderVr(eyes[i].textures[index], eyes[i].rtvs[index], vp, eye, right, up, forward, hud);
                    if (i == 0 && windowRtv) {
                        std::memcpy(mirrorVp, vp, sizeof(mirrorVp));
                        std::memcpy(mirrorEye, eye, sizeof(mirrorEye));
                        std::memcpy(mirrorRight, right, sizeof(mirrorRight));
                        std::memcpy(mirrorUp, up, sizeof(mirrorUp));
                        std::memcpy(mirrorFwd, forward, sizeof(mirrorFwd));
                        mirrorHud = hud;
                        mirror = true;
                    }
                    XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                    xrReleaseSwapchainImage(eyes[i].swapchain, &release);
                    proj[i].type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
                    proj[i].pose = views[i].pose;
                    proj[i].fov = views[i].fov;
                    proj[i].subImage.swapchain = eyes[i].swapchain;
                    proj[i].subImage.imageRect.offset = {0, 0};
                    proj[i].subImage.imageRect.extent = {eyes[i].w, eyes[i].h};
                    eyesDrawn++;
                }
                rendered = eyesDrawn == (int)count && count > 0;
                if (timeThis) {
                    context->End(slot.t1);
                    context->End(slot.disjoint);
                    slot.periodMs = budgetMs;
                    slot.pending = true;
                    timerWrite = (timerWrite + 1) % 3;
                }
                if (mirror && windowRtv)
                    renderer.RenderMirror(windowRtv, windowW, windowH, mirrorVp, mirrorEye, mirrorRight, mirrorUp, mirrorFwd,
                                          mirrorHud);
            }
        }
        const double cpuMs = (double)(GetTickCount64() - t0);
        lastCpuMs = (float)cpuMs;
        second.frames++;
        second.cpuSum += cpuMs;
        setting.frames++;
        setting.cpuSum += cpuMs;
        if (cpuMs > budgetMs * 1.05) {
            int slotIndex = (timerWrite + 2) % 3;
            if (timers[slotIndex].pending) timers[slotIndex].cpuOver = true;
            else {
                second.missed++;
                setting.missed++;
            }
        }
        ReadTimers();
        const ULONGLONG now = GetTickCount64();
        if (lastLogTick == 0) lastLogTick = now;
        if (now - lastLogTick >= 1000) {
            WriteCsv("sample", second);
            second = {};
            lastLogTick = now;
            wchar_t title[256];
            swprintf_s(title, L"VR Resolution Preview  %d x %d  %.0f%%  MSAA %d  GPU %.2f ms", eyeW, eyeH, actualPct, msaa,
                       lastGpuMs);
            if (hwnd) SetWindowTextW(hwnd, title);
        }
        XrCompositionLayerProjection layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        layer.space = space;
        layer.viewCount = rendered ? (uint32_t)viewCount : 0;
        layer.views = proj;
        const XrCompositionLayerBaseHeader* headers[] = {reinterpret_cast<XrCompositionLayerBaseHeader*>(&layer)};
        XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};
        end.displayTime = frame.predictedDisplayTime;
        end.environmentBlendMode = blend;
        end.layerCount = rendered ? 1 : 0;
        end.layers = rendered ? headers : nullptr;
        xrEndFrame(session, &end);
        if (windowSwap && rendered) windowSwap->Present(0, 0);
    }

    HudInfo MakeHud(const std::string& sky) const {
        HudInfo hud;
        hud.eyeW = eyeW;
        hud.eyeH = eyeH;
        hud.recW = recW;
        hud.recH = recH;
        hud.maxW = maxW;
        hud.maxH = maxH;
        hud.requestedPct = pct;
        hud.actualPct = actualPct;
        hud.axisScale = axisScale;
        hud.msaa = msaa;
        hud.gpuMs = lastGpuMs;
        hud.cpuMs = lastCpuMs;
        hud.budgetMs = (float)budgetMs;
        hud.refreshHz = (float)refreshHz;
        hud.missed = setting.missed;
        hud.scene = scene;
        hud.ab = ab;
        hud.abSlot = abSlot;
        hud.abA = abA;
        hud.abB = abB;
        hud.clamped = showClamped;
        hud.help = help;
        std::snprintf(hud.sky, sizeof(hud.sky), "%s", sky.c_str());
        return hud;
    }

    void Shutdown() {
        skyStop.store(true);
        if (skyThread.joinable()) skyThread.join();
        if (skyPixels) {
            stbi_image_free(skyPixels);
            skyPixels = nullptr;
        }
        FlushSummary();
        if (csv) {
            std::fclose(csv);
            csv = nullptr;
        }
        DestroySwapchains();
        renderer.Shutdown();
        for (auto& slot : timers) {
            if (slot.disjoint) slot.disjoint->Release();
            if (slot.t0) slot.t0->Release();
            if (slot.t1) slot.t1->Release();
            slot = {};
        }
        if (windowRtv) {
            windowRtv->Release();
            windowRtv = nullptr;
        }
        windowSwap.Reset();
        context.Reset();
        device.Reset();
        if (space) xrDestroySpace(space);
        if (session) xrDestroySession(session);
        if (instance) xrDestroyInstance(instance);
        space = XR_NULL_HANDLE;
        session = XR_NULL_HANDLE;
        instance = XR_NULL_HANDLE;
    }
};

App* g_app = nullptr;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_CLOSE) {
        DestroyWindow(hwnd);
        return 0;
    }
    if (msg == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    if (msg == WM_SIZE && g_app && g_app->context && g_app->windowSwap && wp != SIZE_MINIMIZED) {
        g_app->windowW = LOWORD(lp);
        g_app->windowH = HIWORD(lp);
        if (g_app->windowW > 0 && g_app->windowH > 0) {
            if (g_app->windowRtv) {
                g_app->windowRtv->Release();
                g_app->windowRtv = nullptr;
            }
            g_app->context->OMSetRenderTargets(0, nullptr, nullptr);
            g_app->windowSwap->ResizeBuffers(0, (UINT)g_app->windowW, (UINT)g_app->windowH, DXGI_FORMAT_UNKNOWN, 0);
            ComPtr<ID3D11Texture2D> back;
            if (SUCCEEDED(g_app->windowSwap->GetBuffer(0, IID_PPV_ARGS(&back))))
                g_app->device->CreateRenderTargetView(back.Get(), nullptr, &g_app->windowRtv);
        }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int Smoke() {
    auto axis = [](double p) { return std::sqrt(p / 100.0); };
    if (std::fabs(axis(100.0) - 1.0) > 1e-9) {
        Print("pixel-percent scale failed the 100% check");
        return 1;
    }
    if (std::fabs(axis(300.0) * axis(300.0) - 3.0) > 1e-6) {
        Print("pixel-percent scale failed the 300% check");
        return 1;
    }
    const double s = axis(300.0);
    const int w = (int)std::lround(4184.0 * s);
    const int h = (int)std::lround(3256.0 * s);
    const double back = (w * (double)h) / (4184.0 * 3256.0) * 100.0;
    if (std::fabs(back - 300.0) > 1.0) {
        Print("4184x3256 at 300% did not land near 3x pixels");
        return 1;
    }

    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 2,
                                   D3D11_SDK_VERSION, &device, nullptr, &context);
    if (FAILED(hr)) {
        Print("WARP device was not created");
        return 1;
    }
    Renderer renderer;
    std::string err;
    if (!renderer.Init(device.Get(), context.Get(), err)) {
        Print(err);
        return 1;
    }
    const int rw = 160, rh = 120;
    if (!renderer.Resize(rw, rh, 1, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, err)) {
        Print(err);
        renderer.Shutdown();
        return 1;
    }
    D3D11_TEXTURE2D_DESC td{};
    td.Width = rw;
    td.Height = rh;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
    td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> dest;
    if (FAILED(device->CreateTexture2D(&td, nullptr, &dest))) {
        Print("smoke target failed");
        renderer.Shutdown();
        return 1;
    }
    ComPtr<ID3D11RenderTargetView> rtv;
    device->CreateRenderTargetView(dest.Get(), nullptr, &rtv);
    float proj[16], view[16], vp[16];
    MatIdentity(view);
    MatProjectionD3D(proj, -0.8f, 0.8f, 0.8f, -0.8f, 0.05f, 800.f);
    MatMul(vp, proj, view);
    const float eye[3] = {0, 0, 0};
    const float right[3] = {1, 0, 0};
    const float up[3] = {0, 1, 0};
    const float forward[3] = {0, 0, -1};
    HudInfo hud;
    hud.eyeW = rw;
    hud.eyeH = rh;
    hud.recW = 4184;
    hud.recH = 3256;
    hud.requestedPct = 100;
    hud.actualPct = 100;
    hud.axisScale = 1;
    hud.msaa = 1;
    hud.budgetMs = 11.1f;
    hud.refreshHz = 90;
    std::snprintf(hud.sky, sizeof(hud.sky), "Sky: procedural");
    renderer.RenderVr(dest.Get(), rtv.Get(), vp, eye, right, up, forward, hud);

    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    td.Usage = D3D11_USAGE_STAGING;
    ComPtr<ID3D11Texture2D> stage;
    if (FAILED(device->CreateTexture2D(&td, nullptr, &stage))) {
        Print("staging texture failed");
        renderer.Shutdown();
        return 1;
    }
    context->CopyResource(stage.Get(), dest.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context->Map(stage.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
        Print("readback failed");
        renderer.Shutdown();
        return 1;
    }
    // The eye chart's exact center can land on a black letter. A small window
    // still covers the white card if the scene rendered.
    int bright = 0;
    uint8_t sample[4] = {};
    for (int y = rh / 2 - 4; y <= rh / 2 + 4; ++y) {
        for (int x = rw / 2 - 4; x <= rw / 2 + 4; ++x) {
            const uint8_t* px = (const uint8_t*)mapped.pData + y * mapped.RowPitch + x * 4;
            const int c = px[0] > px[1] ? (px[0] > px[2] ? px[0] : px[2]) : (px[1] > px[2] ? px[1] : px[2]);
            if (c > bright) {
                bright = c;
                sample[0] = px[0];
                sample[1] = px[1];
                sample[2] = px[2];
                sample[3] = px[3];
            }
        }
    }
    char line[96];
    std::snprintf(line, sizeof(line), "smoke center pixel %u %u %u %u", sample[0], sample[1], sample[2], sample[3]);
    Print(line);
    context->Unmap(stage.Get(), 0);
    if (bright < 100) {
        Print("scene render was unexpectedly dark");
        renderer.Shutdown();
        return 1;
    }
    if (!renderer.Resize(rw, rh, 4, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, err)) {
        Print(err);
        renderer.Shutdown();
        return 1;
    }
    hud.msaa = 4;
    renderer.RenderVr(dest.Get(), rtv.Get(), vp, eye, right, up, forward, hud);

    App logger;
    logger.pct = 300.f;
    logger.actualPct = (float)back;
    logger.axisScale = (float)s;
    logger.eyeW = w;
    logger.eyeH = h;
    logger.recW = 4184;
    logger.recH = 3256;
    logger.msaa = 4;
    logger.scene = SceneAll;
    logger.OpenCsv();
    Accum sample;
    sample.frames = 1;
    sample.gpuSum = 1;
    sample.gpuCount = 1;
    sample.gpuMax = 1;
    sample.cpuSum = 1;
    logger.WriteCsv("sample", sample);
    if (logger.csv) {
        std::fclose(logger.csv);
        logger.csv = nullptr;
    }
    FILE* check = _wfopen(logger.csvPath().c_str(), L"rb");
    if (!check) {
        Print("CSV was not created next to the exe");
        renderer.Shutdown();
        return 1;
    }
    char header[256] = {};
    std::fgets(header, sizeof(header), check);
    std::fclose(check);
    if (!std::strstr(header, "pixel_pct_requested")) {
        Print("CSV header is missing");
        renderer.Shutdown();
        return 1;
    }
    renderer.Shutdown();
    Print("smoke ok");
    return 0;
}

}  // namespace

int main() {
    Options opt;
    if (!ParseArgs(opt)) {
        PrintUsage();
        return 2;
    }
    if (opt.help) {
        PrintUsage();
        return 0;
    }
    if (opt.msaa != 1 && opt.msaa != 2 && opt.msaa != 4 && opt.msaa != 8) opt.msaa = 1;
    opt.pct = Clampf(opt.pct, 50.f, 400.f);
    if (opt.smoke) return Smoke();

    App app;
    g_app = &app;
    app.opt = opt;
    app.pct = opt.pct;
    app.msaa = opt.msaa;
    app.abA = 100.f;
    app.abB = 300.f;

    WNDCLASSW wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"VrResPreview";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassW(&wc);
    RECT rect{0, 0, app.windowW, app.windowH};
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
    app.hwnd = CreateWindowW(L"VrResPreview", L"VR Resolution Preview", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                             rect.right - rect.left, rect.bottom - rect.top, nullptr, nullptr, wc.hInstance, nullptr);
    ShowWindow(app.hwnd, SW_SHOW);

    if (!app.CreateXrDevice()) {
        app.Shutdown();
        return 1;
    }
    app.CreateMirror();
    app.OpenCsv();
    app.StartSky();
    Print("Keyboard: [ ] preset, comma/period +/-5%, 1-7 presets, M msaa, F5/F6 save A/B, Space flip, V scene, H help, Esc quit.");

    while (!app.quit) {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) app.quit = true;
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (app.quit) break;
        app.PollEvents();
        app.PollInput();
        app.ConsumeSky();
        if (app.sessionRunning) app.RenderFrame();
        else Sleep(20);
    }
    app.Shutdown();
    g_app = nullptr;
    return 0;
}
