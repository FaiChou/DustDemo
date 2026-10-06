#include <metal_stdlib>
using namespace metal;

// Independently implemented, following Telegram's snapshot -> grid -> dust approach.
// Source links and the deliberate differences are documented in README.md.
struct DustUniforms {
    float2 viewport;
    float2 origin;
    float2 contentSize;
    uint2 grid;
    float time;
    float seed;
};

struct DustVertex {
    float4 position [[position]];
    float2 uv;
    float opacity;
};

static float random01(uint key) {
    key ^= key >> 16;
    key *= 0x7feb352du;
    key ^= key >> 15;
    key *= 0x846ca68bu;
    key ^= key >> 16;
    return float(key & 0x00ffffffu) / float(0x01000000u);
}

// Integrate the moving activation window analytically. This gives the same
// velocity/acceleration model at 30/60/120 Hz and allows deterministic seeking.
static float activeAge(float time, float xFraction) {
    const float sweepDuration = 0.8;
    const float windowWidth = 0.8;
    float onset = xFraction * sweepDuration / (1.0 + windowWidth);
    float ramp = windowWidth * sweepDuration / (1.0 + windowWidth);
    float local = max(0.0, time - onset);
    return local < ramp ? local * local / (2.0 * ramp) : local - 0.5 * ramp;
}

vertex DustVertex dustVertex(uint vertexID [[vertex_id]],
                             uint particleID [[instance_id]],
                             constant DustUniforms &u [[buffer(0)]]) {
    // Triangle strip; at t=0 all the little tiles exactly reconstruct the image.
    const float2 corners[] = {float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1)};
    float2 corner = corners[vertexID];
    uint2 cell = uint2(particleID % u.grid.x, particleID / u.grid.x);
    float2 tileSize = u.contentSize / float2(u.grid);
    float2 source = (float2(cell) + corner) * tileSize;
    float age = activeAge(u.time, float(cell.x) / float(u.grid.x));

    uint key = particleID + uint(u.seed) * 7919u;
    float angle = random01(key * 3u + 1u) * 6.28318530718;
    float speed = mix(42.0, 84.0, random01(key * 3u + 2u));
    float life = mix(0.7, 1.5, random01(key * 3u + 3u));
    float2 velocity = float2(cos(angle), sin(angle)) * speed;
    // UIKit/SwiftUI coordinates point down: negative Y is upward drift.
    // A slight leftward breeze echoes the reference image.
    float2 displacement = velocity * age + float2(-16.0, -60.0) * age * age;
    float2 point = u.origin + source + displacement;

    DustVertex out;
    out.position = float4(point.x / u.viewport.x * 2.0 - 1.0,
                          1.0 - point.y / u.viewport.y * 2.0, 0.0, 1.0);
    out.uv = source / u.contentSize;
    out.opacity = clamp((life - age) / 0.3, 0.0, 1.0);
    return out;
}

fragment half4 dustFragment(DustVertex in [[stage_in]],
                            texture2d<half> snapshot [[texture(0)]],
                            constant float &layerOpacity [[buffer(0)]]) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    // The uploaded CGImage is premultiplied RGBA, so fade RGB and alpha together.
    return snapshot.sample(imageSampler, in.uv) * half(in.opacity * layerOpacity);
}

// Independent extension: text -> traveling colored particles -> a complete image.
// Every target tile starts at an alpha-tested glyph location, never empty space.
struct MorphUniforms {
    float2 viewport;
    float2 sourceOrigin;
    float2 sourceSize;
    float2 targetOrigin;
    float2 targetSize;
    uint2 grid;
    float time;
    uint sourceCount;
    float cornerRadius;
    float loadingStart;
    float loadingEnd;
    float formationEnd;
};

struct MorphVertex {
    float4 position [[position]];
    float2 sourceUV;
    float2 targetUV;
    float2 targetSize;
    float colorMix;
    float inkMix;
    float opacity;
    float cornerRadius;
};

vertex MorphVertex morphVertex(uint vertexID [[vertex_id]],
                               uint particleID [[instance_id]],
                               constant MorphUniforms &u [[buffer(0)]],
                               const device float4 *glyphs [[buffer(1)]]) {
    const float2 corners[] = {float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1)};
    float2 corner = corners[vertexID];
    uint2 cell = uint2(particleID % u.grid.x, particleID / u.grid.x);
    float2 targetTile = u.targetSize / float2(u.grid);
    float2 targetCenter = u.targetOrigin + (float2(cell) + 0.5) * targetTile;

    uint glyphID = min(u.sourceCount - 1, uint(random01(particleID + 913u) * float(u.sourceCount)));
    float4 glyph = glyphs[glyphID]; // position in points + normalized UV.
    const float tau = 6.28318530718;
    float count = float(u.grid.x * u.grid.y);
    float2 centerOfStage = u.targetOrigin + u.targetSize * 0.5;
    float radius = min(54.0, min(u.targetSize.x, u.targetSize.y) * 0.16);
    float phase = (float(particleID) + 0.5) / count;
    float rotation = (min(u.time, u.loadingEnd) - u.loadingStart) * tau / 1.1;
    float angle = phase * tau * 0.84 + rotation;
    float ringRadius = radius * (1.0 + (random01(particleID + 53u) - 0.5) * 0.18);
    float2 ring = centerOfStage + float2(cos(angle), sin(angle)) * ringRadius;

    // 1. Text fragments travel to a centered rotating ring. No positional clamp:
    // short balanced offsets and interpolation keep paths away from the edges.
    float gather = smoothstep(0.08, u.loadingStart, u.time);
    float scatterAngle = random01(particleID + 181u) * tau;
    float2 scatter = float2(cos(scatterAngle), sin(scatterAngle)) * 12.0 * sin(gather * 3.14159265);
    float2 center = mix(u.sourceOrigin + glyph.xy, ring, gather) + scatter;

    // 2. Hold the complete ring for exactly loadingEnd - loadingStart (2s).
    // Only ~2400 representatives remain visible, avoiding a solid overdraw blob.
    float keep = random01(particleID + 307u) < min(1.0, 2400.0 / count) ? 1.0 : 0.0;
    float head = mix(0.25, 1.0, phase);
    float ringOpacity = keep * head * 0.7;

    // 3. Once loading ends, the ring releases into an isotropic centered cloud.
    // All cloud points lie inside a disk; no particles are pinned to any boundary.
    float burst = smoothstep(u.loadingEnd, u.loadingEnd + 0.6, u.time);
    float cloudAngle = random01(particleID + 409u) * tau;
    float cloudRadius = sqrt(random01(particleID + 601u)) * min(u.targetSize.x, u.targetSize.y) * 0.36;
    float2 cloud = centerOfStage + float2(cos(cloudAngle), sin(cloudAngle)) * cloudRadius;
    if (u.time >= u.loadingEnd) {
        center = mix(ring, cloud, burst);
    }

    // 4. The centered cloud resolves into the complete image. Positions are convex
    // combinations of interior points and destinations, rather than left-biased wind.
    float arrival = u.formationEnd - random01(particleID + 719u) * 0.35;
    float assemble = smoothstep(u.loadingEnd + 0.6, arrival, u.time);
    center = mix(center, targetCenter, assemble);
    float2 size = mix(float2(0.9), targetTile, assemble);
    float2 point = center + (corner - 0.5) * size;

    MorphVertex out;
    out.position = float4(point.x / u.viewport.x * 2.0 - 1.0,
                          1.0 - point.y / u.viewport.y * 2.0, 0, 1);
    out.sourceUV = glyph.zw + (corner - 0.5) / u.sourceSize;
    out.targetUV = (float2(cell) + corner) / float2(u.grid);
    out.targetSize = u.targetSize;
    out.inkMix = smoothstep(0.2, u.loadingStart, u.time);
    out.colorMix = smoothstep(u.loadingEnd, u.loadingEnd + 0.9, u.time);
    float born = smoothstep(0.04, 0.4, u.time);
    float beforeRelease = mix(0.09, ringOpacity, gather);
    float afterRelease = mix(ringOpacity, 0.20, burst);
    out.opacity = born * (u.time < u.loadingEnd ? beforeRelease : mix(afterRelease, 1.0, assemble));
    out.cornerRadius = u.cornerRadius;
    return out;
}

fragment half4 morphFragment(MorphVertex in [[stage_in]],
                             texture2d<half> source [[texture(0)]],
                             texture2d<half> target [[texture(1)]]) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    half4 textColor = source.sample(imageSampler, in.sourceUV);
    half4 imageColor = target.sample(imageSampler, in.targetUV);
    // Crop in the destination tile's UV, not in screen space: even edge particles
    // travel outside the card, then reconstruct a seamless rounded image.
    float2 q = abs((in.targetUV - 0.5) * in.targetSize) - in.targetSize * 0.5 + in.cornerRadius;
    float distance = length(max(q, float2(0))) + min(max(q.x, q.y), 0.0) - in.cornerRadius;
    float mask = in.cornerRadius > 0 ? 1.0 - smoothstep(-0.5, 0.5, distance) : 1.0;
    half4 loadingColor = half4(0.14h, 0.54h, 0.92h, 1.0h);
    half4 movingColor = mix(mix(textColor, loadingColor, half(in.inkMix)), imageColor, half(in.colorMix));
    return movingColor * half(in.opacity * mask);
}
