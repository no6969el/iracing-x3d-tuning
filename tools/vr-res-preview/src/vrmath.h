#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>

// Column-major 4x4, matching the OpenXR xr_linear layout and HLSL's default
// column_major packing. Transform a column vector with M * v.

inline void MatIdentity(float m[16]) {
    std::memset(m, 0, sizeof(float) * 16);
    m[0] = m[5] = m[10] = m[15] = 1.f;
}

inline void MatMul(float out[16], const float a[16], const float b[16]) {
    float r[16];
    for (int c = 0; c < 4; ++c) {
        for (int row = 0; row < 4; ++row) {
            r[c * 4 + row] = a[0 * 4 + row] * b[c * 4 + 0] + a[1 * 4 + row] * b[c * 4 + 1] +
                            a[2 * 4 + row] * b[c * 4 + 2] + a[3 * 4 + row] * b[c * 4 + 3];
        }
    }
    std::memcpy(out, r, sizeof(r));
}

inline void MatFromQuat(float m[16], float x, float y, float z, float w) {
    const float x2 = x + x, y2 = y + y, z2 = z + z;
    const float xx = x * x2, yy = y * y2, zz = z * z2;
    const float xy = x * y2, xz = x * z2, yz = y * z2;
    const float wx = w * x2, wy = w * y2, wz = w * z2;
    MatIdentity(m);
    m[0] = 1.f - yy - zz;
    m[1] = xy + wz;
    m[2] = xz - wy;
    m[4] = xy - wz;
    m[5] = 1.f - xx - zz;
    m[6] = yz + wx;
    m[8] = xz + wy;
    m[9] = yz - wx;
    m[10] = 1.f - xx - yy;
}

// Rigid transform: rotation then translation (camera / object pose).
inline void MatFromPose(float m[16], float px, float py, float pz, float qx, float qy, float qz, float qw) {
    MatFromQuat(m, qx, qy, qz, qw);
    m[12] = px;
    m[13] = py;
    m[14] = pz;
}

inline void MatInvertRigid(float dst[16], const float src[16]) {
    dst[0] = src[0];
    dst[1] = src[4];
    dst[2] = src[8];
    dst[3] = 0.f;
    dst[4] = src[1];
    dst[5] = src[5];
    dst[6] = src[9];
    dst[7] = 0.f;
    dst[8] = src[2];
    dst[9] = src[6];
    dst[10] = src[10];
    dst[11] = 0.f;
    dst[12] = -(src[0] * src[12] + src[1] * src[13] + src[2] * src[14]);
    dst[13] = -(src[4] * src[12] + src[5] * src[13] + src[6] * src[14]);
    dst[14] = -(src[8] * src[12] + src[9] * src[13] + src[10] * src[14]);
    dst[15] = 1.f;
}

// D3D clip space: x,y in [-1,1] with +Y up, z in [0,1]. OpenXR view looks down -Z.
// tan* are tan of the half-angles from XrFovf (left/down are negative).
inline void MatProjectionD3D(float m[16], float tanLeft, float tanRight, float tanUp, float tanDown, float zNear,
                             float zFar) {
    const float tanWidth = tanRight - tanLeft;
    const float tanHeight = tanUp - tanDown;
    std::memset(m, 0, sizeof(float) * 16);
    m[0] = 2.f / tanWidth;
    m[5] = 2.f / tanHeight;
    m[8] = (tanRight + tanLeft) / tanWidth;
    m[9] = (tanUp + tanDown) / tanHeight;
    m[10] = -zFar / (zFar - zNear);
    m[11] = -1.f;
    m[14] = -(zFar * zNear) / (zFar - zNear);
}

inline void MatTranslation(float m[16], float x, float y, float z) {
    MatIdentity(m);
    m[12] = x;
    m[13] = y;
    m[14] = z;
}

// Columns are the local axes in world space, then the translation.
inline void MatAxes(float m[16], float xx, float xy, float xz, float yx, float yy, float yz, float zx, float zy, float zz,
                    float tx, float ty, float tz) {
    std::memset(m, 0, sizeof(float) * 16);
    m[0] = xx;
    m[1] = xy;
    m[2] = xz;
    m[4] = yx;
    m[5] = yy;
    m[6] = yz;
    m[8] = zx;
    m[9] = zy;
    m[10] = zz;
    m[12] = tx;
    m[13] = ty;
    m[14] = tz;
    m[15] = 1.f;
}

inline float Clampf(float v, float lo, float hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}
