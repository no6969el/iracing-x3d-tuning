#pragma once

#include <d3d11.h>
#include <d2d1.h>
#include <dwrite.h>

#include <string>

struct HudInfo {
    int eyeW = 0;
    int eyeH = 0;
    int recW = 0;
    int recH = 0;
    int maxW = 0;
    int maxH = 0;
    float requestedPct = 100.f;
    float actualPct = 100.f;
    float axisScale = 1.f;
    int msaa = 1;
    float gpuMs = 0.f;
    float cpuMs = 0.f;
    float budgetMs = 11.1f;
    float refreshHz = 90.f;
    int missed = 0;
    int scene = 0;
    bool ab = false;
    int abSlot = 0;
    float abA = 100.f;
    float abB = 300.f;
    bool clamped = false;
    bool help = false;
    char sky[192] = "Sky: procedural";
};

// scene ids shared with the CSV and the HUD
enum SceneId {
    SceneAll = 0,
    SceneSharp = 1,
    SceneCharts = 2,
    SceneFence = 3,
    SceneTrack = 4,
    SceneSky = 5,
    SceneCount = 6
};

const char* SceneName(int scene);

class Renderer {
public:
    bool Init(ID3D11Device* device, ID3D11DeviceContext* context, std::string& err);
    void Shutdown();

    // Recreate the MSAA color (when samples > 1) and depth targets for one eye.
    bool Resize(int width, int height, int samples, DXGI_FORMAT colorFormat, std::string& err);

    // Draw the scene into a swapchain image. Resolves MSAA when samples > 1.
    void RenderVr(ID3D11Texture2D* dest, ID3D11RenderTargetView* destRtv, const float viewProj[16], const float eye[3],
                  const float right[3], const float up[3], const float forward[3], const HudInfo& hud);

    // Desktop mirror. Owns a small non-MSAA depth buffer. Outside the GPU timer.
    void RenderMirror(ID3D11RenderTargetView* destRtv, int width, int height, const float viewProj[16], const float eye[3],
                      const float right[3], const float up[3], const float forward[3], const HudInfo& hud);

    // rgba is linear float, tightly packed, row-major. Safe to free after return.
    bool UploadSky(const float* rgba, int width, int height, std::string& err);

    int Width() const { return width_; }
    int Height() const { return height_; }
    int Samples() const { return samples_; }

private:
    struct Draw {
        uint32_t start = 0;
        uint32_t count = 0;
        int mode = 0;
        int mask = 0;
        int kind = 0;  // 0 static, 1 sky, 2 hud
        int tag = 0;   // 1 chart, 2-5 distance labels, 6 hud, 7 sky
        ID3D11ShaderResourceView* srv = nullptr;
    };

    bool Compile(std::string& err);
    bool BuildGeometry(std::string& err);
    bool BuildText(std::string& err);
    void ReleaseTargets();
    void DrawWorld(ID3D11RenderTargetView* rtv, ID3D11DepthStencilView* dsv, int width, int height, const float viewProj[16],
                   const float eye[3], const float right[3], const float up[3], const float forward[3], const HudInfo& hud);
    void UpdateHudTexture(const HudInfo& hud);
    bool MakeTextTexture(const wchar_t* text, int width, int height, float fontPx, ID3D11ShaderResourceView** srv,
                         bool eyeChart);

    ID3D11Device* device_ = nullptr;
    ID3D11DeviceContext* context_ = nullptr;
    ID3D11VertexShader* vs_ = nullptr;
    ID3D11PixelShader* ps_ = nullptr;
    ID3D11InputLayout* layout_ = nullptr;
    ID3D11Buffer* vb_ = nullptr;
    ID3D11Buffer* ib_ = nullptr;
    ID3D11Buffer* cb_ = nullptr;
    ID3D11RasterizerState* rsCull_ = nullptr;
    ID3D11RasterizerState* rsNone_ = nullptr;
    ID3D11DepthStencilState* dsOn_ = nullptr;
    ID3D11DepthStencilState* dsOff_ = nullptr;
    ID3D11BlendState* blendOpaque_ = nullptr;
    ID3D11SamplerState* sampWrap_ = nullptr;
    ID3D11SamplerState* sampClamp_ = nullptr;
    ID3D11ShaderResourceView* white_ = nullptr;
    ID3D11ShaderResourceView* sky_ = nullptr;
    ID3D11ShaderResourceView* chart_ = nullptr;
    ID3D11ShaderResourceView* label_[4] = {};
    ID3D11ShaderResourceView* hudSrv_ = nullptr;
    ID3D11Texture2D* hudTex_ = nullptr;
    ID2D1Factory* d2d_ = nullptr;
    ID2D1RenderTarget* hudRt_ = nullptr;
    ID2D1SolidColorBrush* hudBrush_ = nullptr;
    IDWriteFactory* dwrite_ = nullptr;
    IDWriteTextFormat* hudFormat_ = nullptr;
    IDWriteTextFormat* hudSmall_ = nullptr;

    ID3D11Texture2D* msaaColor_ = nullptr;
    ID3D11RenderTargetView* msaaRtv_ = nullptr;
    ID3D11Texture2D* depth_ = nullptr;
    ID3D11DepthStencilView* dsv_ = nullptr;
    ID3D11Texture2D* mirrorDepth_ = nullptr;
    ID3D11DepthStencilView* mirrorDsv_ = nullptr;
    int mirrorW_ = 0;
    int mirrorH_ = 0;

    Draw draws_[48] = {};
    int drawCount_ = 0;
    int labelSrvCount_ = 0;

    int width_ = 0;
    int height_ = 0;
    int samples_ = 1;
    DXGI_FORMAT format_ = DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
    bool skyReady_ = false;
    std::wstring lastHud_;
};
