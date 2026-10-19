#include <metal_stdlib>
using namespace metal;

// 随心听卡片背景：「流萤之夜」——深夜青渐变 + 极光缎带 + 悬浮萤光点。
// 设计原则：绝不用噪声场/逐像素颗粒；萤点是固定哈希的少量光点（8~14 颗），
// 圆滑高斯截面，动作缓慢清晰，缩到 168px 依旧干净。
// 色板与「流萤」素材同一系：深夜青底、薄荷绿极光、暖金萤火。
// 与 RandomListenMascot.swift 的 PulseUniforms 逐字节对应（5 × float4 = 80B）。

struct PulseUniforms {
  float4 colA;   // 强调色 rgb
  float4 colB;   // 深色底
  float4 a;      // time, bass, mid, treble
  float4 b;      // level, beatAge, hover, live
  float4 c;      // disabled, error, seed, strength
};

struct VSOut {
  float4 pos [[position]];
  float2 ndc;    // 插值得到的 [-1,1] 屏幕坐标（正方形卡片，无宽高比问题）
};

vertex VSOut pulse_vertex(uint vid [[vertex_id]]) {
  // 超尺寸全屏三角形：(0,0) (2,0) (0,2) → clip (-1,-1) (3,-1) (-1,3)
  float2 corner = float2(float((vid << 1) & 2), float(vid & 2));
  float2 clip = corner * 2.0 - 1.0;
  VSOut out_;
  out_.pos = float4(clip, 0.0, 1.0);
  out_.ndc = clip;
  return out_;
}

static float hash11(float x) { return fract(sin(x * 127.1 + 311.7) * 43758.5453); }

fragment float4 pulse_fragment(VSOut vin [[stage_in]],
                               constant PulseUniforms &u [[buffer(0)]]) {
  float2 p = vin.ndc;
  float t = u.a.x;
  float bass = u.a.y;
  float mid = u.a.z;
  float treble = u.a.w;
  float level = u.b.x;
  float beatAge = u.b.y;
  float hover = u.b.z;
  float live = u.b.w;
  float disabled = u.c.x;
  float error = u.c.y;
  float seed = u.c.z;
  float strength = u.c.w;

  const float3 mint = float3(0.42, 0.95, 0.74);  // 薄荷（流萤主色）
  const float3 gold = float3(1.00, 0.83, 0.45);  // 暖金（流萤点缀）

  // 深夜青竖向渐变：上方更暗沉入夜色，下方稍亮衬住角色
  float up = p.y * 0.5 + 0.5;
  float3 col = u.colB.rgb * (0.62 + 0.58 * up);

  // 中央舞台辉光：角色身后的一团柔光，响度/低频推亮，聚焦视觉中心
  float d2 = dot(p, p);
  float stage = exp(-d2 / 0.42) * (0.045 + 0.10 * level + 0.10 * bass * live);
  col += mix(mint, gold, 0.22) * stage;

  // 极光：两条上下摆动的正弦缎带（薄荷 + 淡金），中频控制亮度。
  // 是解析式波带而不是噪声场，边缘高斯柔化，永远干净。
  for (int i = 0; i < 2; i++) {
    float fi = float(i);
    float cy = 0.02 + 0.42 * fi;
    float wave = cy
               + 0.20 * sin(p.x * 1.6 + t * (0.22 + 0.05 * fi) + 2.1 * fi + seed * 0.31)
               + 0.09 * sin(p.x * 3.3 - t * 0.30 + 1.7 * fi);
    float ribbon = exp(-pow((p.y - wave) / 0.16, 2.0));
    // 缎带两端渐隐 + 极缓慢的横向明暗流动，避免呆板
    ribbon *= 0.55 + 0.45 * sin(p.x * 0.9 + t * (0.13 + 0.04 * fi) + fi * 2.2);
    float gain = (i == 0) ? (0.038 + 0.085 * mid) : (0.022 + 0.055 * level);
    col += (i == 0 ? mint : gold) * ribbon * gain;
  }

  // 萤火：12 颗固定哈希光点缓速上浮 + 左右摇曳，高频让光点更亮、
  // 击拍时齐齐上跃一小截。少量、清晰、圆形——与"噪点"是两回事。
  float beatKick = exp(-beatAge * 5.0) * live;
  for (int i = 0; i < 12; i++) {
    float fi = float(i) + seed;
    float h1 = hash11(fi), h2 = hash11(fi * 1.37 + 7.0);
    float h3 = hash11(fi * 2.11 + 31.0), h4 = hash11(fi * 0.91 + 53.0);
    float x = h1 * 2.0 - 1.0;
    float speed = 0.045 + 0.055 * h2;
    float y = -1.25 + fract(h2 + t * speed) * 2.5;
    x += 0.11 * sin(t * (0.45 + 0.5 * h3) + h4 * 6.28);
    y += beatKick * 0.06 * (0.5 + h3);
    float size = 0.016 + 0.020 * h3;
    float q2 = dot(p - float2(x, y), p - float2(x, y));
    float g = exp(-q2 / (size * size));
    // 呼吸微光：各自错相闪烁；无声兜底时也保留基本亮度不至于死黑
    float twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * (1.6 + 2.6 * h3) + h2 * 6.28));
    float gain = (0.10 + 0.20 * treble + 0.10 * beatKick) * mix(0.55, 1.0, twinkle) * mix(0.4, 1.0, live);
    col += mix(gold, mint, h4) * g * gain;
  }

  // 节拍：整体柔和辉光脉冲（不用扩散圆环——小尺寸下圆环显脏）
  if (beatAge < 0.5) {
    float pulse = exp(-beatAge * 7.0) * exp(-d2 / 0.9);
    col += mix(mint, gold, 0.35) * pulse * (0.05 + 0.20 * bass);
  }

  // 温和压角（比旧版减半，夜色本就该四周沉下去）
  col *= 1.0 - 0.16 * dot(p, p);

  // 悬停提亮
  col *= (1.0 + hover * 0.14);

  // 失败态偏红
  float glow = dot(max(col - u.colB.rgb, 0.0), float3(0.34));
  col = mix(col, mix(u.colB.rgb, float3(0.42, 0.13, 0.12), glow * 1.6 + 0.20), error);

  // 禁用降饱和 + 整体强度
  float luma = dot(col, float3(0.299, 0.587, 0.114));
  col = mix(float3(luma), col, clamp(1.0 - disabled, 0.0, 1.0) * 0.72 + 0.28);
  col *= mix(0.72, 1.0, strength);

  // 去色带用的极轻微抖动（0.3%，不构成颗粒感）
  float2 pp = floor(vin.pos.xy);
  col += (fract(sin(dot(pp, float2(12.9898, 78.233)) + seed) * 43758.5453) - 0.5) * 0.003;

  return float4(max(col, 0.0), 1.0);
}
