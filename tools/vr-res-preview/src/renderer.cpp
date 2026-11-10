#include "renderer.h"

#include "vrmath.h"

#include <d3dcompiler.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

const char* kShader = R"HLSL(
cbuffer CB : register(b0) {
    float4x4 gWorld;
    float4x4 gViewProj;
    float4 gEye;
    float4 gMisc; // x mode, y unused, z exposure, w sky ready
};

struct VSIn {
    float3 pos : POSITION;
    float3 nrm : NORMAL;
    float2 uv : TEXCOORD0;
    float3 color : COLOR;
    float param : TEXCOORD1;
};

struct VSOut {
    float4 clip : SV_Position;
    float3 world : TEXCOORD0;
    float3 nrm : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float3 color : COLOR0;
    float param : TEXCOORD3;
};

Texture2D gSky : register(t0);
Texture2D gAlbedo : register(t1);
SamplerState gSamp : register(s0);
SamplerState gSampClamp : register(s1);

VSOut vsMain(VSIn i) {
    VSOut o;
    float4 w = mul(gWorld, float4(i.pos, 1));
    o.world = w.xyz;
    o.clip = mul(gViewProj, w);
    o.nrm = mul((float3x3)gWorld, i.nrm);
    o.uv = i.uv;
    o.color = i.color;
    o.param = i.param;
    return o;
}

float3 Sky(float3 dir) {
    float3 d = normalize(dir);
    if (gMisc.w > 0.5) {
        float lon = atan2(d.z, d.x);
        float lat = asin(clamp(d.y, -1.0, 1.0));
        float2 uv = float2(lon * 0.15915494309 + 0.5, 0.5 - lat * 0.31830988618);
        float3 hdr = gSky.Sample(gSamp, uv).rgb * gMisc.z;
        return hdr / (1.0 + hdr);
    }
    float t = saturate(d.y * 0.55 + 0.35);
    float3 col = lerp(float3(0.55, 0.68, 0.78), float3(0.08, 0.22, 0.55), t);
    float3 sun = normalize(float3(-0.35, 0.48, 0.80));
    col += pow(saturate(dot(d, sun)), 900.0) * float3(1.3, 1.15, 0.85);
    col += pow(saturate(1.0 - abs(d.y)), 7.0) * float3(0.28, 0.24, 0.20);
    return col;
}

float4 psMain(VSOut i) : SV_Target {
    int mode = (int)(gMisc.x + 0.5);
    if (mode == 5) {
        return float4(Sky(i.world - gEye.xyz), 1);
    }
    if (mode == 2) {
        float2 p = i.uv * 2.0 - 1.0;
        float r = length(p);
        if (r > 1.0) discard;
        float a = atan2(p.y, p.x);
        float sectors = max(i.param, 8.0);
        float spoke = sin(a * sectors) > 0.0 ? 1.0 : 0.0;
        float ring = sin(r * sectors * 2.0) > 0.0 ? 1.0 : 0.0;
        float v = spoke * 0.82 + ring * 0.18;
        if (r < 0.035) v = 1.0;
        return float4(v, v, v, 1);
    }
    if (mode == 3) {
        float freq = max(i.param, 1.0);
        float bars = frac(i.uv.x * freq) > 0.5 ? 1.0 : 0.0;
        float lines = frac(i.uv.y * freq * 0.35) > 0.5 ? 1.0 : 0.0;
        float chirp = sin(i.uv.x * i.uv.x * freq * freq * 0.15) > 0.0 ? 1.0 : 0.0;
        float v = (i.uv.y < 0.34) ? bars : ((i.uv.y < 0.67) ? lines : chirp);
        return float4(v, v, v, 1);
    }
    if (mode == 4) {
        float2 uv = i.uv * max(i.param, 1.0);
        float2 cell = abs(frac(uv) - 0.5);
        float d = abs(cell.x - cell.y);
        float wire = min(cell.x, cell.y);
        if (wire > 0.045 && d > 0.04) discard;
        return float4(0.82, 0.84, 0.88, 1);
    }
    if (mode == 1) {
        float x = i.world.x;
        float z = i.world.z;
        float3 col = float3(0.11, 0.11, 0.12);
        float grain = frac(sin(dot(floor(i.world.xz * 48.0), float2(127.1, 311.7))) * 43758.5);
        col *= 0.86 + 0.14 * grain;
        bool edge = abs(abs(x) - 4.0) < 0.055;
        bool dash = abs(x) < 0.03 && frac(-z * 0.22) < 0.42;
        bool stripe = abs(z + 18.0) < 0.06 && abs(x) < 4.0;
        if (edge || dash || stripe) col = float3(0.93, 0.93, 0.95);
        if (abs(abs(x) - 4.4) < 0.26) {
            float k = frac((x + z) * 1.6) > 0.5 ? 1.0 : 0.0;
            col = lerp(float3(0.75, 0.12, 0.08), float3(0.92, 0.92, 0.92), k);
        }
        return float4(col, 1);
    }
    if (mode == 6) {
        float4 t = gAlbedo.Sample(gSampClamp, i.uv);
        return float4(pow(max(t.rgb, 0.0), 2.2), 1);
    }
    if (mode == 7) {
        return float4(i.color, 1);
    }
    float3 n = normalize(i.nrm);
    float3 l = normalize(float3(-0.25, 0.85, 0.35));
    float ndl = saturate(dot(n, l));
    return float4(i.color * (0.22 + 0.78 * ndl), 1);
}
)HLSL";

struct Vtx {
    float px, py, pz;
    float nx, ny, nz;
    float u, v;
    float r, g, b;
    float param;
};

struct CB {
    float world[16];
    float viewProj[16];
    float eye[4];
    float misc[4];
};

uint16_t FloatToHalf(float f) {
    uint32_t x = 0;
    std::memcpy(&x, &f, 4);
    const uint32_t sign = (x >> 16) & 0x8000u;
    int32_t exp = (int32_t)((x >> 23) & 0xff) - 127 + 15;
    uint32_t mant = x & 0x7fffffu;
    if ((x & 0x7fffffffu) > 0x7f800000u) return (uint16_t)(sign | 0x7e00u);
    if (exp <= 0) {
        if (exp < -10) return (uint16_t)sign;
        mant |= 0x800000u;
        const uint32_t shift = (uint32_t)(14 - exp);
        uint32_t half = mant >> shift;
        if ((mant >> (shift - 1)) & 1u) half += 1;
        return (uint16_t)(sign | half);
    }
    if (exp >= 31) return (uint16_t)(sign | 0x7c00u);
    uint16_t half = (uint16_t)(sign | ((uint32_t)exp << 10) | (mant >> 13));
    if (mant & 0x1000u) half = (uint16_t)(half + 1);
    return half;
}

int SceneMaskOf(int scene) {
    switch (scene) {
        case SceneSharp: return 1;
        case SceneCharts: return 2;
        case SceneFence: return 4;
        case SceneTrack: return 8;
        case SceneSky: return 0;
        default: return 1 | 2 | 4 | 8;
    }
}

const char* HResultText(HRESULT hr) {
    static char buf[96];
    std::snprintf(buf, sizeof(buf), "%s (0x%08X)", HResultName(hr), (unsigned)hr);
    return buf;
}

void (*g_d3dSink)(const std::string& line) = nullptr;
std::string g_d3dFailure;
std::string g_d3dFailureBrief;

HRESULT EmitD3d(HRESULT hr, const char* call, const char* what, const char* detail) {
    char line[512];
    std::snprintf(line, sizeof(line), "D3D11 %s %s -> %s%s%s", call, what, HResultText(hr), detail[0] ? "  " : "",
                  detail);
    if (FAILED(hr)) {
        g_d3dFailure = line;
        g_d3dFailureBrief = std::string(call) + " " + what + " " + HResultName(hr);
    }
    if (g_d3dSink) g_d3dSink(line);
    return hr;
}

void DescText(char* out, size_t size, const D3D11_TEXTURE2D_DESC& td) {
    std::snprintf(out, size, "%ux%u %s samples %u array %u mips %u bind 0x%X misc 0x%X", td.Width, td.Height,
                  DxgiFormatName(td.Format), td.SampleDesc.Count, td.ArraySize, td.MipLevels, td.BindFlags,
                  td.MiscFlags);
}

}  // namespace

void SetD3dLogSink(void (*sink)(const std::string& line)) { g_d3dSink = sink; }

HRESULT LogD3d(HRESULT hr, const char* call, const char* what) { return EmitD3d(hr, call, what, ""); }

HRESULT LogD3d(HRESULT hr, const char* call, const char* what, const D3D11_TEXTURE2D_DESC& td) {
    char detail[256];
    DescText(detail, sizeof(detail), td);
    return EmitD3d(hr, call, what, detail);
}

HRESULT LogD3dView(HRESULT hr, const char* call, const char* what, DXGI_FORMAT viewFormat, ID3D11Resource* resource) {
    char tex[256] = "unknown texture";
    ComPtr<ID3D11Texture2D> tex2d;
    if (resource && SUCCEEDED(resource->QueryInterface(IID_PPV_ARGS(&tex2d)))) {
        D3D11_TEXTURE2D_DESC td{};
        tex2d->GetDesc(&td);
        DescText(tex, sizeof(tex), td);
    }
    char detail[320];
    std::snprintf(detail, sizeof(detail), "view %s on %s",
                  viewFormat == DXGI_FORMAT_UNKNOWN ? "default (null desc)" : DxgiFormatName(viewFormat), tex);
    return EmitD3d(hr, call, what, detail);
}

std::string LastD3dFailure(bool brief) { return brief ? g_d3dFailureBrief : g_d3dFailure; }

void ClearD3dFailure() {
    g_d3dFailure.clear();
    g_d3dFailureBrief.clear();
}

const char* DxgiFormatName(DXGI_FORMAT format) {
    switch (format) {
        case DXGI_FORMAT_UNKNOWN: return "UNKNOWN";
        case DXGI_FORMAT_R8G8B8A8_TYPELESS: return "R8G8B8A8_TYPELESS";
        case DXGI_FORMAT_R8G8B8A8_UNORM: return "R8G8B8A8_UNORM";
        case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: return "R8G8B8A8_UNORM_SRGB";
        case DXGI_FORMAT_B8G8R8A8_TYPELESS: return "B8G8R8A8_TYPELESS";
        case DXGI_FORMAT_B8G8R8A8_UNORM: return "B8G8R8A8_UNORM";
        case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: return "B8G8R8A8_UNORM_SRGB";
        case DXGI_FORMAT_R10G10B10A2_UNORM: return "R10G10B10A2_UNORM";
        case DXGI_FORMAT_R16G16B16A16_FLOAT: return "R16G16B16A16_FLOAT";
        case DXGI_FORMAT_R11G11B10_FLOAT: return "R11G11B10_FLOAT";
        case DXGI_FORMAT_D32_FLOAT: return "D32_FLOAT";
        case DXGI_FORMAT_D24_UNORM_S8_UINT: return "D24_UNORM_S8_UINT";
        case DXGI_FORMAT_D16_UNORM: return "D16_UNORM";
        default: {
            static char buf[32];
            std::snprintf(buf, sizeof(buf), "DXGI_FORMAT %d", (int)format);
            return buf;
        }
    }
}

const char* HResultName(HRESULT hr) {
    switch (hr) {
        case S_OK: return "S_OK";
        case S_FALSE: return "S_FALSE";
        case E_INVALIDARG: return "E_INVALIDARG";
        case E_OUTOFMEMORY: return "E_OUTOFMEMORY";
        case E_FAIL: return "E_FAIL";
        case E_NOTIMPL: return "E_NOTIMPL";
        case DXGI_ERROR_INVALID_CALL: return "DXGI_ERROR_INVALID_CALL";
        case DXGI_ERROR_UNSUPPORTED: return "DXGI_ERROR_UNSUPPORTED";
        case DXGI_ERROR_DEVICE_REMOVED: return "DXGI_ERROR_DEVICE_REMOVED";
        case DXGI_ERROR_DEVICE_HUNG: return "DXGI_ERROR_DEVICE_HUNG";
        case DXGI_ERROR_DEVICE_RESET: return "DXGI_ERROR_DEVICE_RESET";
        case DXGI_ERROR_DRIVER_INTERNAL_ERROR: return "DXGI_ERROR_DRIVER_INTERNAL_ERROR";
        default: return SUCCEEDED(hr) ? "success" : "HRESULT";
    }
}

const char* SceneName(int scene) {
    switch (scene) {
        case SceneAll: return "All";
        case SceneSharp: return "Sharpness";
        case SceneCharts: return "Charts";
        case SceneFence: return "Fence";
        case SceneTrack: return "Track";
        case SceneSky: return "Sky";
        default: return "All";
    }
}

bool Renderer::Compile(std::string& err) {
    UINT flags = D3DCOMPILE_OPTIMIZATION_LEVEL3 | D3DCOMPILE_ENABLE_STRICTNESS;
    ComPtr<ID3DBlob> vsBlob, psBlob, errors;
    HRESULT hr = D3DCompile(kShader, std::strlen(kShader), "scene.hlsl", nullptr, nullptr, "vsMain", "vs_5_0", flags, 0,
                            &vsBlob, &errors);
    if (FAILED(hr)) {
        err = errors ? (const char*)errors->GetBufferPointer() : "vertex shader failed";
        return false;
    }
    errors.Reset();
    hr = D3DCompile(kShader, std::strlen(kShader), "scene.hlsl", nullptr, nullptr, "psMain", "ps_5_0", flags, 0, &psBlob,
                    &errors);
    if (FAILED(hr)) {
        err = errors ? (const char*)errors->GetBufferPointer() : "pixel shader failed";
        return false;
    }
    hr = LogD3d(device_->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &vs_),
                "CreateVertexShader", "scene");
    if (FAILED(hr)) {
        err = "CreateVertexShader failed";
        return false;
    }
    hr = LogD3d(device_->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &ps_),
                "CreatePixelShader", "scene");
    if (FAILED(hr)) {
        err = "CreatePixelShader failed";
        return false;
    }
    const D3D11_INPUT_ELEMENT_DESC layout[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"NORMAL", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 24, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 32, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 1, DXGI_FORMAT_R32_FLOAT, 0, 44, D3D11_INPUT_PER_VERTEX_DATA, 0},
    };
    hr = LogD3d(device_->CreateInputLayout(layout, 5, vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), &layout_),
                "CreateInputLayout", "scene");
    if (FAILED(hr)) {
        err = "CreateInputLayout failed";
        return false;
    }
    return true;
}

bool Renderer::BuildGeometry(std::string& err) {
    std::vector<Vtx> verts;
    std::vector<uint32_t> indices;
    drawCount_ = 0;

    auto addVert = [&](float px, float py, float pz, float nx, float ny, float nz, float u, float v, float r, float g,
                       float b, float param) {
        verts.push_back(Vtx{px, py, pz, nx, ny, nz, u, v, r, g, b, param});
    };
    auto addTri = [&](uint32_t a, uint32_t b, uint32_t c) {
        indices.push_back(a);
        indices.push_back(b);
        indices.push_back(c);
    };
    auto begin = [&]() { return (uint32_t)indices.size(); };
    auto finish = [&](uint32_t start, int mode, int mask, int kind, int tag) {
        if (drawCount_ >= (int)(sizeof(draws_) / sizeof(draws_[0]))) {
            err = "too many draw calls";
            return false;
        }
        Draw d;
        d.start = start;
        d.count = (uint32_t)indices.size() - start;
        d.mode = mode;
        d.mask = mask;
        d.kind = kind;
        d.tag = tag;
        draws_[drawCount_++] = d;
        return true;
    };

    auto addFace = [&](float x0, float y0, float z0, float x1, float y1, float z1, float x2, float y2, float z2, float x3,
                       float y3, float z3, float nx, float ny, float nz, float r, float g, float b, float param) {
        uint32_t base = (uint32_t)verts.size();
        addVert(x0, y0, z0, nx, ny, nz, 0, 1, r, g, b, param);
        addVert(x1, y1, z1, nx, ny, nz, 1, 1, r, g, b, param);
        addVert(x2, y2, z2, nx, ny, nz, 1, 0, r, g, b, param);
        addVert(x3, y3, z3, nx, ny, nz, 0, 0, r, g, b, param);
        addTri(base, base + 1, base + 2);
        addTri(base, base + 2, base + 3);
    };
    auto addBox = [&](float cx, float cy, float cz, float hx, float hy, float hz, float r, float g, float b) {
        const float x0 = cx - hx, x1 = cx + hx, y0 = cy - hy, y1 = cy + hy, z0 = cz - hz, z1 = cz + hz;
        addFace(x0, y0, z1, x1, y0, z1, x1, y1, z1, x0, y1, z1, 0, 0, 1, r, g, b, 0);
        addFace(x1, y0, z0, x0, y0, z0, x0, y1, z0, x1, y1, z0, 0, 0, -1, r, g, b, 0);
        addFace(x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1, 1, 0, 0, r, g, b, 0);
        addFace(x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0, -1, 0, 0, r, g, b, 0);
        addFace(x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0, 0, 1, 0, r, g, b, 0);
        addFace(x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1, 0, -1, 0, r, g, b, 0);
    };
    auto addQuad = [&](float cx, float cy, float cz, float ax, float ay, float az, float bx, float by, float bz, float w,
                       float h, float r, float g, float b, float param) {
        const float hw = w * 0.5f, hh = h * 0.5f;
        const float nx = ay * bz - az * by;
        const float ny = az * bx - ax * bz;
        const float nz = ax * by - ay * bx;
        auto at = [&](float su, float sv, float& ox, float& oy, float& oz) {
            ox = cx + ax * su + bx * sv;
            oy = cy + ay * su + by * sv;
            oz = cz + az * su + bz * sv;
        };
        float x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3;
        at(-hw, -hh, x0, y0, z0);
        at(hw, -hh, x1, y1, z1);
        at(hw, hh, x2, y2, z2);
        at(-hw, hh, x3, y3, z3);
        addFace(x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3, nx, ny, nz, r, g, b, param);
    };
    auto addCyl = [&](float cx, float cy, float cz, float ax, float ay, float az, float radius, float length, int sides,
                      float r, float g, float b) {
        const float alen = std::sqrt(ax * ax + ay * ay + az * az);
        ax /= alen;
        ay /= alen;
        az /= alen;
        float tx = 0, ty = 1, tz = 0;
        if (std::fabs(ay) > 0.85f) {
            tx = 1;
            ty = 0;
        }
        float ux = ty * az - tz * ay, uy = tz * ax - tx * az, uz = tx * ay - ty * ax;
        float ul = std::sqrt(ux * ux + uy * uy + uz * uz);
        ux /= ul;
        uy /= ul;
        uz /= ul;
        float vx = ay * uz - az * uy, vy = az * ux - ax * uz, vz = ax * uy - ay * ux;
        const float hl = length * 0.5f;
        for (int s = 0; s < sides; ++s) {
            const float a0 = (float)s / (float)sides * 6.2831853f;
            const float a1 = (float)(s + 1) / (float)sides * 6.2831853f;
            const float c0 = std::cos(a0), s0 = std::sin(a0), c1 = std::cos(a1), s1 = std::sin(a1);
            auto ring = [&](float along, float cc, float ss, float& ox, float& oy, float& oz) {
                ox = cx + ax * along + (ux * cc + vx * ss) * radius;
                oy = cy + ay * along + (uy * cc + vy * ss) * radius;
                oz = cz + az * along + (uz * cc + vz * ss) * radius;
            };
            float p0x, p0y, p0z, p1x, p1y, p1z, p2x, p2y, p2z, p3x, p3y, p3z;
            ring(hl, c0, s0, p0x, p0y, p0z);
            ring(hl, c1, s1, p1x, p1y, p1z);
            ring(-hl, c1, s1, p2x, p2y, p2z);
            ring(-hl, c0, s0, p3x, p3y, p3z);
            const float nx = ux * (c0 + c1) * 0.5f + vx * (s0 + s1) * 0.5f;
            const float ny = uy * (c0 + c1) * 0.5f + vy * (s0 + s1) * 0.5f;
            const float nz = uz * (c0 + c1) * 0.5f + vz * (s0 + s1) * 0.5f;
            addFace(p0x, p0y, p0z, p1x, p1y, p1z, p2x, p2y, p2z, p3x, p3y, p3z, nx, ny, nz, r, g, b, 0);
        }
    };

    // Sky sphere, unit radius, recentered on the eye each frame.
    {
        const uint32_t start = begin();
        const int stacks = 28, slices = 48;
        for (int y = 0; y <= stacks; ++y) {
            const float v = (float)y / (float)stacks;
            const float phi = v * 3.14159265f;
            for (int x = 0; x <= slices; ++x) {
                const float u = (float)x / (float)slices;
                const float theta = u * 6.2831853f;
                const float sx = std::sin(phi) * std::cos(theta);
                const float sy = std::cos(phi);
                const float sz = std::sin(phi) * std::sin(theta);
                addVert(sx, sy, sz, -sx, -sy, -sz, u, v, 1, 1, 1, 0);
            }
        }
        for (int y = 0; y < stacks; ++y) {
            for (int x = 0; x < slices; ++x) {
                const uint32_t i0 = (uint32_t)(y * (slices + 1) + x);
                const uint32_t i1 = i0 + 1;
                const uint32_t i2 = i0 + (slices + 1);
                const uint32_t i3 = i2 + 1;
                addTri(i0, i2, i1);
                addTri(i1, i2, i3);
            }
        }
        if (!finish(start, 5, 0, 1, 7)) return false;
    }

    const float ground = -1.40f;

    // Track surface. Analytic paint so distant lines alias with resolution.
    {
        const uint32_t start = begin();
        addQuad(0, ground, -70.f, 1, 0, 0, 0, 0, -1, 24.f, 150.f, 0.1f, 0.1f, 0.1f, 0);
        if (!finish(start, 1, 8, 0, 0)) return false;
    }

    // Solid track furniture: car, gantries, marker poles, chart frames.
    {
        const uint32_t start = begin();
        const float cx = 2.2f, cz = -12.f;
        addBox(cx, ground + 0.48f, cz, 0.58f, 0.16f, 1.65f, 0.72f, 0.07f, 0.05f);
        addBox(cx, ground + 0.40f, cz - 1.7f, 0.28f, 0.10f, 0.42f, 0.72f, 0.07f, 0.05f);
        addBox(cx, ground + 0.72f, cz + 0.1f, 0.36f, 0.14f, 0.40f, 0.05f, 0.05f, 0.06f);
        addBox(cx, ground + 0.86f, cz + 1.55f, 0.72f, 0.008f, 0.16f, 0.12f, 0.12f, 0.13f);
        addBox(cx - 0.72f, ground + 0.80f, cz + 1.55f, 0.008f, 0.14f, 0.20f, 0.92f, 0.92f, 0.94f);
        addBox(cx + 0.72f, ground + 0.80f, cz + 1.55f, 0.008f, 0.14f, 0.20f, 0.92f, 0.92f, 0.94f);
        const float wy = ground + 0.30f;
        addCyl(cx - 0.72f, wy, cz - 1.05f, 1, 0, 0, 0.30f, 0.22f, 14, 0.02f, 0.02f, 0.02f);
        addCyl(cx + 0.72f, wy, cz - 1.05f, 1, 0, 0, 0.30f, 0.22f, 14, 0.02f, 0.02f, 0.02f);
        addCyl(cx - 0.78f, wy, cz + 1.15f, 1, 0, 0, 0.32f, 0.26f, 14, 0.02f, 0.02f, 0.02f);
        addCyl(cx + 0.78f, wy, cz + 1.15f, 1, 0, 0, 0.32f, 0.26f, 14, 0.02f, 0.02f, 0.02f);

        auto gantry = [&](float z) {
            addBox(-4.35f, ground + 1.9f, z, 0.012f, 1.9f, 0.012f, 0.72f, 0.75f, 0.80f);
            addBox(4.35f, ground + 1.9f, z, 0.012f, 1.9f, 0.012f, 0.72f, 0.75f, 0.80f);
            addBox(0, ground + 3.72f, z, 4.35f, 0.008f, 0.01f, 0.85f, 0.86f, 0.90f);
        };
        gantry(-26.f);
        gantry(-60.f);
        gantry(-100.f);
        if (!finish(start, 0, 8, 0, 0)) return false;
    }

    // Orange posts and frames so the eye charts stay findable at long range.
    {
        const uint32_t start = begin();
        const float chartZ[4] = {-1.f, -5.f, -20.f, -100.f};
        for (float z : chartZ) {
            addBox(-1.15f, ground + 1.15f, z - 0.02f, 0.012f, 1.15f, 0.012f, 1.f, 0.42f, 0.05f);
            addQuad(-0.15f, -0.05f, z - 0.03f, 1, 0, 0, 0, 1, 0, 0.82f, 1.08f, 1.f, 0.42f, 0.05f, 0);
        }
        if (!finish(start, 0, 2, 0, 0)) return false;
    }

    // Thin wires and fence posts. Geometric edges are what MSAA changes.
    {
        const uint32_t start = begin();
        for (int i = 0; i <= 40; ++i) {
            const float x = -3.f + (6.f * (float)i / 40.f);
            addBox(x, ground + 0.75f, -4.6f, 0.0022f, 0.75f, 0.0022f, 0.90f, 0.92f, 0.95f);
        }
        for (int i = 0; i < 6; ++i) {
            addBox(0, ground + 0.18f + (float)i * 0.26f, -4.6f, 3.0f, 0.0018f, 0.0018f, 0.90f, 0.92f, 0.95f);
        }
        for (int i = 0; i < 8; ++i) {
            const float z = -8.f - (float)i * 12.f;
            addBox(-3.4f, ground + 1.6f, z, 0.004f, 1.6f, 0.004f, 0.75f, 0.78f, 0.82f);
            addBox(3.4f, ground + 1.6f, z, 0.004f, 1.6f, 0.004f, 0.75f, 0.78f, 0.82f);
        }
        for (int i = 0; i < 3; ++i) {
            addBox(-2.4f, ground + 2.7f + (float)i * 0.28f, -62.f, 0.0025f, 0.0025f, 58.f, 0.95f, 0.93f, 0.85f);
        }
        if (!finish(start, 7, 4, 0, 0)) return false;
    }

    // Alpha-tested chain link, which MSAA does not clean up.
    {
        const uint32_t start = begin();
        addQuad(0, ground + 0.75f, -4.85f, 1, 0, 0, 0, 1, 0, 6.3f, 1.55f, 0.8f, 0.8f, 0.85f, 28.f);
        if (!finish(start, 4, 4, 0, 0)) return false;
    }

    // Siemens stars. Sector count is per vertex so one draw holds several.
    {
        const uint32_t start = begin();
        addQuad(0.95f, 0.05f, -2.0f, 1, 0, 0, 0, 1, 0, 0.72f, 0.72f, 1, 1, 1, 36.f);
        addQuad(0.95f, 0.05f, -8.0f, 1, 0, 0, 0, 1, 0, 0.72f, 0.72f, 1, 1, 1, 90.f);
        addQuad(0.95f, 0.15f, -25.f, 1, 0, 0, 0, 1, 0, 1.1f, 1.1f, 1, 1, 1, 160.f);
        if (!finish(start, 2, 1, 0, 0)) return false;
    }

    // Line / chirp panels.
    {
        const uint32_t start = begin();
        addQuad(0.95f, -0.55f, -3.2f, 1, 0, 0, 0, 1, 0, 0.8f, 0.55f, 1, 1, 1, 24.f);
        addQuad(0.95f, -0.55f, -12.f, 1, 0, 0, 0, 1, 0, 0.9f, 0.6f, 1, 1, 1, 70.f);
        addQuad(1.3f, 0.2f, -40.f, 1, 0, 0, 0, 1, 0, 2.4f, 1.4f, 1, 1, 1, 90.f);
        if (!finish(start, 3, 1, 0, 0)) return false;
    }

    // Eye charts, one texture, four distances.
    {
        const uint32_t start = begin();
        const float zs[4] = {-1.f, -5.f, -20.f, -100.f};
        for (float z : zs) addQuad(-0.15f, -0.05f, z, 1, 0, 0, 0, 1, 0, 0.70f, 0.94f, 1, 1, 1, 0);
        if (!finish(start, 6, 2, 0, 1)) return false;
    }

    // Distance labels.
    {
        const float zs[4] = {-1.f, -5.f, -20.f, -100.f};
        for (int i = 0; i < 4; ++i) {
            const uint32_t start = begin();
            addQuad(-0.15f, 0.58f, zs[i], 1, 0, 0, 0, 1, 0, 0.55f, 0.16f, 1, 1, 1, 0);
            if (!finish(start, 6, 2, 0, 2 + i)) return false;
        }
    }

    // Head-locked HUD quad in local XY, placed each frame.
    {
        const uint32_t start = begin();
        addQuad(0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 0);
        if (!finish(start, 6, 0, 2, 6)) return false;
    }

    if (verts.empty() || indices.empty()) {
        err = "empty mesh";
        return false;
    }
    D3D11_BUFFER_DESC bd{};
    bd.ByteWidth = (UINT)(verts.size() * sizeof(Vtx));
    bd.Usage = D3D11_USAGE_IMMUTABLE;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA sd{};
    sd.pSysMem = verts.data();
    HRESULT hr = LogD3d(device_->CreateBuffer(&bd, &sd, &vb_), "CreateBuffer", "vertices");
    if (FAILED(hr)) {
        err = std::string("vertex buffer ") + HResultText(hr);
        return false;
    }
    bd.ByteWidth = (UINT)(indices.size() * sizeof(uint32_t));
    bd.BindFlags = D3D11_BIND_INDEX_BUFFER;
    sd.pSysMem = indices.data();
    hr = LogD3d(device_->CreateBuffer(&bd, &sd, &ib_), "CreateBuffer", "indices");
    if (FAILED(hr)) {
        err = std::string("index buffer ") + HResultText(hr);
        return false;
    }
    return true;
}

bool Renderer::MakeTextTexture(const wchar_t* text, int width, int height, float fontPx, ID3D11ShaderResourceView** srv,
                               bool eyeChart) {
    D3D11_TEXTURE2D_DESC td{};
    td.Width = (UINT)width;
    td.Height = (UINT)height;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> tex;
    HRESULT hr = LogD3d(device_->CreateTexture2D(&td, nullptr, &tex), "CreateTexture2D", "text", td);
    if (FAILED(hr)) return false;
    ComPtr<IDXGISurface> surface;
    hr = tex->QueryInterface(IID_PPV_ARGS(&surface));
    if (FAILED(hr)) return false;
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.f, 96.f);
    ComPtr<ID2D1RenderTarget> rt;
    hr = d2d_->CreateDxgiSurfaceRenderTarget(surface.Get(), &props, &rt);
    if (FAILED(hr)) return false;

    const wchar_t* families[] = {L"Segoe UI", L"Arial", L"Calibri"};
    ComPtr<IDWriteTextFormat> format;
    for (const wchar_t* family : families) {
        hr = dwrite_->CreateTextFormat(family, nullptr, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL,
                                       DWRITE_FONT_STRETCH_NORMAL, fontPx, L"en-us", &format);
        if (SUCCEEDED(hr)) break;
    }
    if (!format) return false;
    format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);

    rt->BeginDraw();
    if (eyeChart) {
        rt->Clear(D2D1::ColorF(D2D1::ColorF::White));
        ComPtr<ID2D1SolidColorBrush> black;
        rt->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::Black), &black);
        ComPtr<IDWriteTextFormat> title;
        dwrite_->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL,
                                  DWRITE_FONT_STRETCH_NORMAL, 54.f, L"en-us", &title);
        if (title) {
            title->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
            const wchar_t* heading = L"EYE CHART";
            rt->DrawText(heading, (UINT32)wcslen(heading), title.Get(), D2D1::RectF(40, 30, (float)width - 40, 120),
                         black.Get());
        }
        const wchar_t* lines[] = {L"E",           L"F P",         L"T O Z",        L"L P E D",
                                  L"P E C F D",   L"E D F C Z P", L"F E L O P Z D", L"D E F P O T E C",
                                  L"F E Z O L C T D"};
        const float sizes[] = {150.f, 112.f, 84.f, 62.f, 46.f, 34.f, 26.f, 18.f, 13.f};
        float y = 140.f;
        const float bottom = (float)height - 120.f;
        const float band = (bottom - y) / 9.f;
        for (int i = 0; i < 9; ++i) {
            ComPtr<IDWriteTextFormat> line;
            dwrite_->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL,
                                      DWRITE_FONT_STRETCH_NORMAL, sizes[i], L"en-us", &line);
            if (!line) continue;
            line->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
            line->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
            rt->DrawText(lines[i], (UINT32)wcslen(lines[i]), line.Get(),
                         D2D1::RectF(30, y, (float)width - 30, y + band), black.Get());
            y += band;
        }
        ComPtr<IDWriteTextFormat> foot;
        dwrite_->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                  DWRITE_FONT_STRETCH_NORMAL, 36.f, L"en-us", &foot);
        if (foot) {
            foot->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
            const wchar_t* note = L"same panel at 1 m, 5 m, 20 m, 100 m";
            rt->DrawText(note, (UINT32)wcslen(note), foot.Get(),
                         D2D1::RectF(40, (float)height - 100, (float)width - 40, (float)height - 30), black.Get());
        }
    } else {
        rt->Clear(D2D1::ColorF(0.05f, 0.05f, 0.06f));
        ComPtr<ID2D1SolidColorBrush> white;
        rt->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White), &white);
        rt->DrawText(text, (UINT32)wcslen(text), format.Get(), D2D1::RectF(8, 4, (float)width - 8, (float)height - 4),
                     white.Get());
    }
    hr = rt->EndDraw();
    if (FAILED(hr)) return false;
    hr = LogD3dView(device_->CreateShaderResourceView(tex.Get(), nullptr, srv), "CreateShaderResourceView", "text",
                    DXGI_FORMAT_UNKNOWN, tex.Get());
    return SUCCEEDED(hr);
}

bool Renderer::BuildText(std::string& err) {
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &d2d_);
    if (FAILED(hr)) {
        err = "D2D1CreateFactory failed";
        return false;
    }
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                             reinterpret_cast<IUnknown**>(&dwrite_));
    if (FAILED(hr)) {
        err = "DWriteCreateFactory failed";
        return false;
    }
    if (!MakeTextTexture(L"EYE CHART", 2048, 2048, 64.f, &chart_, true)) {
        err = "eye chart text failed";
        return false;
    }
    const wchar_t* labels[] = {L"1 m", L"5 m", L"20 m", L"100 m"};
    for (int i = 0; i < 4; ++i) {
        if (!MakeTextTexture(labels[i], 1024, 256, 140.f, &label_[i], false)) {
            err = "distance label failed";
            return false;
        }
    }
    labelSrvCount_ = 4;

    D3D11_TEXTURE2D_DESC td{};
    td.Width = 1024;
    td.Height = 512;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    hr = LogD3d(device_->CreateTexture2D(&td, nullptr, &hudTex_), "CreateTexture2D", "HUD", td);
    if (FAILED(hr)) {
        err = "HUD texture failed";
        return false;
    }
    ComPtr<IDXGISurface> surface;
    hudTex_->QueryInterface(IID_PPV_ARGS(&surface));
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.f, 96.f);
    hr = d2d_->CreateDxgiSurfaceRenderTarget(surface.Get(), &props, &hudRt_);
    if (FAILED(hr)) {
        err = "HUD Direct2D target failed";
        return false;
    }
    hr = hudRt_->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White), &hudBrush_);
    if (FAILED(hr)) {
        err = "HUD brush failed";
        return false;
    }
    hr = dwrite_->CreateTextFormat(L"Consolas", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                  DWRITE_FONT_STRETCH_NORMAL, 22.f, L"en-us", &hudFormat_);
    if (FAILED(hr)) {
        hr = dwrite_->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                      DWRITE_FONT_STRETCH_NORMAL, 22.f, L"en-us", &hudFormat_);
    }
    if (FAILED(hr)) {
        err = "HUD font failed";
        return false;
    }
    hudFormat_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
    hudFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
    dwrite_->CreateTextFormat(L"Consolas", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                              DWRITE_FONT_STRETCH_NORMAL, 18.f, L"en-us", &hudSmall_);

    for (int i = 0; i < drawCount_; ++i) {
        if (draws_[i].tag == 1) draws_[i].srv = chart_;
        if (draws_[i].tag >= 2 && draws_[i].tag <= 5) draws_[i].srv = label_[draws_[i].tag - 2];
        if (draws_[i].tag == 6) draws_[i].srv = nullptr;  // filled after HUD srv exists
    }
    hr = LogD3dView(device_->CreateShaderResourceView(hudTex_, nullptr, &hudSrv_), "CreateShaderResourceView", "HUD",
                    DXGI_FORMAT_UNKNOWN, hudTex_);
    if (FAILED(hr)) {
        err = "HUD shader view failed";
        return false;
    }
    for (int i = 0; i < drawCount_; ++i) {
        if (draws_[i].tag == 6) draws_[i].srv = hudSrv_;
    }
    return true;
}

bool Renderer::Init(ID3D11Device* device, ID3D11DeviceContext* context, std::string& err) {
    device_ = device;
    context_ = context;
    if (!Compile(err)) return false;

    D3D11_BUFFER_DESC bd{};
    bd.ByteWidth = sizeof(CB);
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(LogD3d(device_->CreateBuffer(&bd, nullptr, &cb_), "CreateBuffer", "constants"))) {
        err = "constant buffer failed";
        return false;
    }

    D3D11_RASTERIZER_DESC rd{};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_BACK;
    rd.FrontCounterClockwise = TRUE;
    rd.DepthClipEnable = TRUE;
    if (FAILED(LogD3d(device_->CreateRasterizerState(&rd, &rsCull_), "CreateRasterizerState", "cull"))) {
        err = "rasterizer failed";
        return false;
    }
    rd.CullMode = D3D11_CULL_NONE;
    if (FAILED(LogD3d(device_->CreateRasterizerState(&rd, &rsNone_), "CreateRasterizerState", "no cull"))) {
        err = "rasterizer failed";
        return false;
    }

    D3D11_DEPTH_STENCIL_DESC dd{};
    dd.DepthEnable = TRUE;
    dd.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
    dd.DepthFunc = D3D11_COMPARISON_LESS;
    if (FAILED(LogD3d(device_->CreateDepthStencilState(&dd, &dsOn_), "CreateDepthStencilState", "on"))) {
        err = "depth state failed";
        return false;
    }
    dd.DepthEnable = FALSE;
    dd.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
    if (FAILED(LogD3d(device_->CreateDepthStencilState(&dd, &dsOff_), "CreateDepthStencilState", "off"))) {
        err = "depth state failed";
        return false;
    }

    D3D11_BLEND_DESC blend{};
    blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    if (FAILED(LogD3d(device_->CreateBlendState(&blend, &blendOpaque_), "CreateBlendState", "opaque"))) {
        err = "blend state failed";
        return false;
    }

    D3D11_SAMPLER_DESC sd{};
    sd.Filter = D3D11_FILTER_ANISOTROPIC;
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
    sd.MaxAnisotropy = 8;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
    if (FAILED(LogD3d(device_->CreateSamplerState(&sd, &sampWrap_), "CreateSamplerState", "wrap"))) {
        err = "sampler failed";
        return false;
    }
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MaxAnisotropy = 1;
    if (FAILED(LogD3d(device_->CreateSamplerState(&sd, &sampClamp_), "CreateSamplerState", "clamp"))) {
        err = "sampler failed";
        return false;
    }

    const uint32_t whitePx = 0xffffffffu;
    D3D11_TEXTURE2D_DESC td{};
    td.Width = td.Height = 1;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA init{};
    init.pSysMem = &whitePx;
    init.SysMemPitch = 4;
    ComPtr<ID3D11Texture2D> whiteTex;
    if (FAILED(LogD3d(device_->CreateTexture2D(&td, &init, &whiteTex), "CreateTexture2D", "white", td))) {
        err = "white texture failed";
        return false;
    }
    if (FAILED(LogD3dView(device_->CreateShaderResourceView(whiteTex.Get(), nullptr, &white_), "CreateShaderResourceView",
                          "white", DXGI_FORMAT_UNKNOWN, whiteTex.Get()))) {
        err = "white view failed";
        return false;
    }
    const uint32_t blackPx = 0xff000000u;
    init.pSysMem = &blackPx;
    ComPtr<ID3D11Texture2D> blackTex;
    if (FAILED(LogD3d(device_->CreateTexture2D(&td, &init, &blackTex), "CreateTexture2D", "sky placeholder", td))) {
        err = "placeholder sky failed";
        return false;
    }
    if (FAILED(LogD3dView(device_->CreateShaderResourceView(blackTex.Get(), nullptr, &sky_), "CreateShaderResourceView",
                          "sky placeholder", DXGI_FORMAT_UNKNOWN, blackTex.Get()))) {
        err = "placeholder sky view failed";
        return false;
    }

    if (!BuildGeometry(err)) return false;
    if (!BuildText(err)) return false;
    return true;
}

void Renderer::ReleaseTargets() {
    if (dsv_) {
        dsv_->Release();
        dsv_ = nullptr;
    }
    if (depth_) {
        depth_->Release();
        depth_ = nullptr;
    }
    if (msaaRtv_) {
        msaaRtv_->Release();
        msaaRtv_ = nullptr;
    }
    if (msaaColor_) {
        msaaColor_->Release();
        msaaColor_ = nullptr;
    }
}

bool Renderer::Resize(int width, int height, int samples, DXGI_FORMAT colorFormat, std::string& err) {
    if (width < 2 || height < 2 || samples < 1) {
        err = "bad target size";
        return false;
    }
    ReleaseTargets();
    format_ = colorFormat;
    samples_ = samples;
    width_ = width;
    height_ = height;

    D3D11_TEXTURE2D_DESC td{};
    td.Width = (UINT)width;
    td.Height = (UINT)height;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_D32_FLOAT;
    td.SampleDesc.Count = (UINT)samples;
    td.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    HRESULT hr = LogD3d(device_->CreateTexture2D(&td, nullptr, &depth_), "CreateTexture2D", "eye depth", td);
    if (FAILED(hr)) {
        err = std::string("depth target ") + HResultText(hr);
        ReleaseTargets();
        return false;
    }
    hr = LogD3dView(device_->CreateDepthStencilView(depth_, nullptr, &dsv_), "CreateDepthStencilView", "eye depth",
                    DXGI_FORMAT_UNKNOWN, depth_);
    if (FAILED(hr)) {
        err = std::string("depth view ") + HResultText(hr);
        ReleaseTargets();
        return false;
    }
    if (samples > 1) {
        td.Format = colorFormat;
        td.BindFlags = D3D11_BIND_RENDER_TARGET;
        hr = LogD3d(device_->CreateTexture2D(&td, nullptr, &msaaColor_), "CreateTexture2D", "MSAA color", td);
        if (FAILED(hr)) {
            err = std::string("MSAA color ") + HResultText(hr);
            ReleaseTargets();
            return false;
        }
        hr = LogD3dView(device_->CreateRenderTargetView(msaaColor_, nullptr, &msaaRtv_), "CreateRenderTargetView",
                        "MSAA color", DXGI_FORMAT_UNKNOWN, msaaColor_);
        if (FAILED(hr)) {
            err = std::string("MSAA view ") + HResultText(hr);
            ReleaseTargets();
            return false;
        }
    }
    return true;
}

void Renderer::UpdateHudTexture(const HudInfo& hud) {
    wchar_t block[1400];
    const wchar_t* msaa = L"off";
    if (hud.msaa == 2) msaa = L"2x";
    else if (hud.msaa == 4) msaa = L"4x";
    else if (hud.msaa == 8) msaa = L"8x";
    wchar_t sky[192];
    MultiByteToWideChar(CP_UTF8, 0, hud.sky, -1, sky, 192);
    if (!hud.help) {
        swprintf_s(block,
                   L"VR resolution preview\n"
                   L"%d x %d per eye    %.0f%%    axis %.3fx\n"
                   L"runtime 100%%  %d x %d    max %d x %d%s\n"
                   L"MSAA %s    GPU %.2f ms    CPU %.2f ms\n"
                   L"budget %.2f ms (%.0f Hz)    missed %d\n"
                   L"scene %hs    A/B %s   now %s\n"
                   L"A %.0f%%    B %.0f%%\n"
                   L"%s\n"
                   L"[ ] preset    , . step    M msaa    Space flip    H help%hs%hs",
                   hud.eyeW, hud.eyeH, hud.actualPct, hud.axisScale, hud.recW, hud.recH, hud.maxW, hud.maxH,
                   hud.clamped ? L"    CLAMPED" : L"", msaa, hud.gpuMs, hud.cpuMs, hud.budgetMs, hud.refreshHz,
                   hud.missed, SceneName(hud.scene), hud.ab ? L"on" : L"off", hud.ab ? (hud.abSlot ? L"B" : L"A") : L"-",
                   hud.abA, hud.abB, sky, hud.notice[0] ? "\n" : "", hud.notice);
    } else {
        swprintf_s(block,
                   L"Controls\n"
                   L"[ ]  or triggers     previous / next preset\n"
                   L", .  or grips        -5%% / +5%% pixels     1-7 presets\n"
                   L"M    or A / X        MSAA off, 2x, 4x, 8x\n"
                   L"F5   or X (left)     save this scale as A\n"
                   L"F6                   save this scale as B\n"
                   L"Space or B / Y       flip A and B\n"
                   L"V    or Y / stick    next scene\n"
                   L"Esc                  quit\n"
                   L"\n"
                   L"Percent counts pixels, same as SteamVR.\n"
                   L"Width scale is sqrt(percent / 100).\n"
                   L"Leave this app at 100%% in SteamVR.\n"
                   L"%s",
                   sky);
    }
    if (lastHud_ == block) return;
    lastHud_ = block;
    if (!hudRt_ || !hudBrush_ || !hudFormat_) return;
    hudRt_->BeginDraw();
    hudRt_->Clear(D2D1::ColorF(0.03f, 0.035f, 0.045f));
    IDWriteTextFormat* format = (hud.help && hudSmall_) ? hudSmall_ : hudFormat_;
    hudRt_->DrawText(block, (UINT32)wcslen(block), format, D2D1::RectF(28, 20, 996, 492), hudBrush_);
    hudRt_->EndDraw();
}

void Renderer::DrawWorld(ID3D11RenderTargetView* rtv, ID3D11DepthStencilView* dsv, int width, int height,
                         const float viewProj[16], const float eye[3], const float right[3], const float up[3],
                         const float forward[3], const HudInfo& hud) {
    if (!rtv) return;
    UpdateHudTexture(hud);
    context_->OMSetRenderTargets(1, &rtv, dsv);
    const float clear[4] = {0.02f, 0.025f, 0.03f, 1.f};
    context_->ClearRenderTargetView(rtv, clear);
    if (dsv) context_->ClearDepthStencilView(dsv, D3D11_CLEAR_DEPTH, 1.f, 0);
    D3D11_VIEWPORT vp{};
    vp.Width = (float)width;
    vp.Height = (float)height;
    vp.MaxDepth = 1.f;
    context_->RSSetViewports(1, &vp);

    UINT stride = sizeof(Vtx), offset = 0;
    context_->IASetInputLayout(layout_);
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->IASetVertexBuffers(0, 1, &vb_, &stride, &offset);
    context_->IASetIndexBuffer(ib_, DXGI_FORMAT_R32_UINT, 0);
    context_->VSSetShader(vs_, nullptr, 0);
    context_->PSSetShader(ps_, nullptr, 0);
    ID3D11SamplerState* samplers[2] = {sampWrap_, sampClamp_};
    context_->PSSetSamplers(0, 2, samplers);
    context_->OMSetBlendState(blendOpaque_, nullptr, 0xffffffffu);
    ID3D11ShaderResourceView* sky = sky_ ? sky_ : white_;
    context_->PSSetShaderResources(0, 1, &sky);

    const int mask = SceneMaskOf(hud.scene);
    const float hudW = 0.96f;
    const float hudH = hud.help ? 0.72f : 0.46f;
    const float hudDist = 1.2f;
    const float hudDrop = hud.help ? -0.18f : -0.46f;

    for (int i = 0; i < drawCount_; ++i) {
        const Draw& d = draws_[i];
        if (d.count == 0) continue;
        if (d.kind == 0) {
            if (hud.scene == SceneSky) continue;
            if (d.mask != 0 && (d.mask & mask) == 0) continue;
        }
        float world[16];
        if (d.kind == 1) {
            MatAxes(world, 500.f, 0, 0, 0, 500.f, 0, 0, 0, 500.f, eye[0], eye[1], eye[2]);
        } else if (d.kind == 2) {
            const float cx = eye[0] + forward[0] * hudDist + up[0] * hudDrop;
            const float cy = eye[1] + forward[1] * hudDist + up[1] * hudDrop;
            const float cz = eye[2] + forward[2] * hudDist + up[2] * hudDrop;
            MatAxes(world, right[0] * hudW, right[1] * hudW, right[2] * hudW, up[0] * hudH, up[1] * hudH, up[2] * hudH,
                    -forward[0], -forward[1], -forward[2], cx, cy, cz);
        } else {
            MatIdentity(world);
        }

        CB cb{};
        std::memcpy(cb.world, world, sizeof(cb.world));
        std::memcpy(cb.viewProj, viewProj, sizeof(cb.viewProj));
        cb.eye[0] = eye[0];
        cb.eye[1] = eye[1];
        cb.eye[2] = eye[2];
        cb.misc[0] = (float)d.mode;
        cb.misc[2] = 0.55f;
        cb.misc[3] = skyReady_ ? 1.f : 0.f;
        D3D11_MAPPED_SUBRESOURCE mapped{};
        if (SUCCEEDED(context_->Map(cb_, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
            std::memcpy(mapped.pData, &cb, sizeof(cb));
            context_->Unmap(cb_, 0);
        }
        context_->VSSetConstantBuffers(0, 1, &cb_);
        context_->PSSetConstantBuffers(0, 1, &cb_);
        ID3D11ShaderResourceView* albedo = d.srv ? d.srv : white_;
        context_->PSSetShaderResources(1, 1, &albedo);
        context_->RSSetState(d.mode == 5 ? rsNone_ : rsCull_);
        context_->OMSetDepthStencilState(d.kind == 2 ? dsOff_ : dsOn_, 0);
        context_->DrawIndexed(d.count, d.start, 0);
    }

    ID3D11ShaderResourceView* none[2] = {nullptr, nullptr};
    context_->PSSetShaderResources(0, 2, none);
    context_->OMSetRenderTargets(0, nullptr, nullptr);
}

void Renderer::RenderVr(ID3D11Texture2D* dest, ID3D11RenderTargetView* destRtv, const float viewProj[16], const float eye[3],
                        const float right[3], const float up[3], const float forward[3], const HudInfo& hud) {
    if (samples_ > 1 && msaaRtv_ && dest) {
        DrawWorld(msaaRtv_, dsv_, width_, height_, viewProj, eye, right, up, forward, hud);
        context_->ResolveSubresource(dest, 0, msaaColor_, 0, format_);
    } else {
        DrawWorld(destRtv, dsv_, width_, height_, viewProj, eye, right, up, forward, hud);
    }
}

void Renderer::RenderMirror(ID3D11RenderTargetView* destRtv, int width, int height, const float viewProj[16],
                            const float eye[3], const float right[3], const float up[3], const float forward[3],
                            const HudInfo& hud) {
    if (width != mirrorW_ || height != mirrorH_ || !mirrorDsv_) {
        if (mirrorDsv_) {
            mirrorDsv_->Release();
            mirrorDsv_ = nullptr;
        }
        if (mirrorDepth_) {
            mirrorDepth_->Release();
            mirrorDepth_ = nullptr;
        }
        D3D11_TEXTURE2D_DESC td{};
        td.Width = (UINT)width;
        td.Height = (UINT)height;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_D32_FLOAT;
        td.SampleDesc.Count = 1;
        td.BindFlags = D3D11_BIND_DEPTH_STENCIL;
        if (FAILED(LogD3d(device_->CreateTexture2D(&td, nullptr, &mirrorDepth_), "CreateTexture2D", "mirror depth", td))) return;
        if (FAILED(LogD3dView(device_->CreateDepthStencilView(mirrorDepth_, nullptr, &mirrorDsv_), "CreateDepthStencilView",
                              "mirror depth", DXGI_FORMAT_UNKNOWN, mirrorDepth_)))
            return;
        mirrorW_ = width;
        mirrorH_ = height;
    }
    DrawWorld(destRtv, mirrorDsv_, width, height, viewProj, eye, right, up, forward, hud);
}

bool Renderer::UploadSky(const float* rgba, int width, int height, std::string& err) {
    if (!rgba || width < 2 || height < 2) {
        err = "empty sky";
        return false;
    }
    UINT levels = 1;
    int m = width > height ? width : height;
    while (m > 1) {
        m >>= 1;
        ++levels;
    }
    std::vector<uint16_t> half((size_t)width * (size_t)height * 4);
    const size_t n = half.size();
    for (size_t i = 0; i < n; ++i) half[i] = FloatToHalf(rgba[i]);

    D3D11_TEXTURE2D_DESC td{};
    td.Width = (UINT)width;
    td.Height = (UINT)height;
    td.MipLevels = levels;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    td.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
    ComPtr<ID3D11Texture2D> tex;
    HRESULT hr = LogD3d(device_->CreateTexture2D(&td, nullptr, &tex), "CreateTexture2D", "sky", td);
    if (FAILED(hr)) {
        err = std::string("sky texture ") + HResultText(hr);
        return false;
    }
    context_->UpdateSubresource(tex.Get(), 0, nullptr, half.data(), (UINT)width * 8, 0);
    ID3D11ShaderResourceView* view = nullptr;
    hr = LogD3dView(device_->CreateShaderResourceView(tex.Get(), nullptr, &view), "CreateShaderResourceView", "sky",
                    DXGI_FORMAT_UNKNOWN, tex.Get());
    if (FAILED(hr)) {
        err = "sky view failed";
        return false;
    }
    context_->GenerateMips(view);
    if (sky_) sky_->Release();
    sky_ = view;
    skyReady_ = true;
    for (int i = 0; i < drawCount_; ++i) {
        if (draws_[i].tag == 7) draws_[i].srv = sky_;
    }
    return true;
}

void Renderer::Shutdown() {
    ReleaseTargets();
    if (mirrorDsv_) mirrorDsv_->Release();
    if (mirrorDepth_) mirrorDepth_->Release();
    mirrorDsv_ = nullptr;
    mirrorDepth_ = nullptr;
    if (hudRt_) hudRt_->Release();
    if (hudBrush_) hudBrush_->Release();
    if (hudFormat_) hudFormat_->Release();
    if (hudSmall_) hudSmall_->Release();
    if (dwrite_) dwrite_->Release();
    if (d2d_) d2d_->Release();
    if (hudSrv_) hudSrv_->Release();
    if (hudTex_) hudTex_->Release();
    hudRt_ = nullptr;
    hudBrush_ = nullptr;
    hudFormat_ = nullptr;
    hudSmall_ = nullptr;
    dwrite_ = nullptr;
    d2d_ = nullptr;
    hudSrv_ = nullptr;
    hudTex_ = nullptr;
    if (chart_) chart_->Release();
    chart_ = nullptr;
    for (int i = 0; i < 4; ++i) {
        if (label_[i]) label_[i]->Release();
        label_[i] = nullptr;
    }
    if (sky_) sky_->Release();
    if (white_) white_->Release();
    sky_ = nullptr;
    white_ = nullptr;
    if (sampWrap_) sampWrap_->Release();
    if (sampClamp_) sampClamp_->Release();
    if (blendOpaque_) blendOpaque_->Release();
    if (dsOn_) dsOn_->Release();
    if (dsOff_) dsOff_->Release();
    if (rsCull_) rsCull_->Release();
    if (rsNone_) rsNone_->Release();
    if (cb_) cb_->Release();
    if (ib_) ib_->Release();
    if (vb_) vb_->Release();
    if (layout_) layout_->Release();
    if (ps_) ps_->Release();
    if (vs_) vs_->Release();
    sampWrap_ = sampClamp_ = nullptr;
    blendOpaque_ = nullptr;
    dsOn_ = dsOff_ = nullptr;
    rsCull_ = rsNone_ = nullptr;
    cb_ = ib_ = vb_ = nullptr;
    layout_ = nullptr;
    ps_ = nullptr;
    vs_ = nullptr;
    device_ = nullptr;
    context_ = nullptr;
}
