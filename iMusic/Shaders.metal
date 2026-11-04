#include <metal_stdlib>
using namespace metal;

// 随心听卡片背景：「雾海流萤·梦境」——深夜青沉入靛蓝夜幕，星云雾缓缓游弋，
// 梦境光斑随低频呼吸，极光缎带与流萤在雾里若隐若现。整体朦胧梦幻但不浑浊：
// 雾用大尺度平滑三角函数场（无逐像素 hash 颗粒），光斑是宽高斯柔光，
// 缩到 168px 依旧干净。律动耦合：低频→光斑呼吸/舞台辉光，中频→雾与极光，
// 高频→流萤闪烁，响度→全场明度与雾浓度，击拍→光斑膨胀 + 全场柔光涌动。
// 底部另有经典 LED 频谱地板：24 列 × 8 层彩色方块随谱逐格增减点亮
// （24 段能量经 buffer(1) 传入，横向扫彩虹、纵向错相、顶层块更亮）；
// 唱片四周再绕一圈径向频谱环（左右镜像，低频在底、高频在顶，同一套彩虹配色）。
// 色板与「流萤」素材同一系：深夜青底、薄荷绿极光、暖金萤火，另调一抹淡紫入梦。
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

// 紧凑 HSV→RGB（频谱方块配色用）
static float3 hsv2rgb(float3 c) {
  float3 rgb = clamp(abs(fract(c.x + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
  return c.z * mix(float3(1.0), rgb, c.y);
}

// 大尺度平滑雾场：两组低频三角函数叠加 + 域扭曲，输出约 [-1,1]。
// 故意不用逐像素 hash：朦胧来自低频起伏，不是颗粒，小尺寸下不脏。
static float mistField(float2 p, float t, float scale) {
  float2 q = p * scale;
  // 域扭曲 + 整体缓摆：雾在原地游弋而非单向滚动
  q += 0.30 * float2(sin(q.y * 0.83 + t * 0.31), cos(q.x * 0.71 - t * 0.24));
  q += 0.18 * float2(sin(t * 0.09), cos(t * 0.06));
  float n = sin(q.x + t * 0.11) * sin(q.y - t * 0.09);
  n += 0.55 * sin(q.x * 0.57 - t * 0.07 + 1.7) * sin(q.y * 0.63 + t * 0.08 + 0.6);
  return n / 1.55;
}

fragment float4 pulse_fragment(VSOut vin [[stage_in]],
                               constant PulseUniforms &u [[buffer(0)]],
                               constant float *bars [[buffer(1)]]) {
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

  const float3 mint  = float3(0.42, 0.95, 0.74);  // 薄荷（流萤主色）
  const float3 gold  = float3(1.00, 0.83, 0.45);  // 暖金（流萤点缀）
  const float3 lilac = float3(0.58, 0.52, 0.98);  // 淡紫（梦境氛围）

  // 节拍双包络：快涌（光斑/流萤）+ 慢回（全场柔光）
  float beatKick  = exp(-beatAge * 5.0) * live;
  float beatSwell = exp(-beatAge * 2.2) * live;
  float liveMix = mix(0.55, 1.0, live); // 兜底模拟律动时整体收敛一档

  // ---- 夜色：深夜青底，上缘沉入靛蓝夜幕，拉出梦境纵深 ----
  float up = p.y * 0.5 + 0.5;
  float3 col = u.colB.rgb * (0.60 + 0.55 * up);
  col = mix(col, float3(0.055, 0.070, 0.145), 0.50 * (1.0 - up));

  // ---- 星云雾：两层大尺度雾场反向游弋，中频/响度点亮雾浓度 ----
  float mistSpeed = 0.55 + 0.45 * live; // 播放时雾被律动带得稍快
  float fogA = smoothstep(0.05, 0.95, mistField(p, t * mistSpeed, 1.30));
  float fogB = smoothstep(0.10, 1.00, mistField(p + float2(3.7 + seed * 0.13, -1.9), t * mistSpeed, 1.85));
  float fogGain = (0.020 + 0.052 * mid + 0.020 * level) * liveMix;
  col += mint * fogA * fogGain;
  col += mix(lilac, gold, 0.25) * fogB * fogGain * 0.8;

  // ---- 中央舞台辉光：角色身后一团柔光，低频把它撑得更宽更亮 ----
  float d2 = dot(p, p);
  float stage = exp(-d2 / (0.50 + 0.25 * bass * live + 0.10 * beatSwell))
              * (0.045 + 0.10 * level + 0.12 * bass * live);
  col += mix(mint, lilac, 0.30) * stage;

  // ---- 梦境光斑：7 颗大光斑沿利萨如轨迹缓漂，低频呼吸、击拍轻胀 ----
  // 宽高斯截面 + 低增益叠加，是"雾里透光"而非清晰的圆
  for (int i = 0; i < 7; i++) {
    float fi = float(i) + seed * 0.37;
    float h1 = hash11(fi * 1.13 + 3.7);
    float h2 = hash11(fi * 2.31 + 11.0);
    float h3 = hash11(fi * 0.77 + 29.0);
    float h4 = hash11(fi * 1.71 + 47.0);
    float2 c = float2(
      0.62 * sin(t * (0.045 + 0.035 * h1) + h2 * 6.2832),
      0.58 * sin(t * (0.038 + 0.030 * h2) + h3 * 6.2832 + 1.1)
    );
    float r = 0.20 + 0.15 * h3;
    r *= 1.0 + (0.12 * bass + 0.06 * level) * live + beatKick * 0.10;
    float g = exp(-dot(p - c, p - c) / (r * r));
    float3 tint = mix(mint, lilac, h4 * 0.8);
    tint = mix(tint, gold, h1 * 0.35);
    col += tint * g * (0.026 + 0.055 * level + 0.035 * beatKick) * liveMix;
  }

  // ---- 极光：两条上下摆动的正弦缎带，雾化处理（更宽、峰值更低）----
  for (int i = 0; i < 2; i++) {
    float fi = float(i);
    float cy = 0.04 + 0.40 * fi + 0.03 * beatSwell;
    float wave = cy
               + 0.20 * sin(p.x * 1.6 + t * (0.22 + 0.05 * fi) + 2.1 * fi + seed * 0.31)
               + 0.09 * sin(p.x * 3.3 - t * 0.30 + 1.7 * fi);
    float ribbon = exp(-pow((p.y - wave) / 0.26, 2.0));
    ribbon *= 0.55 + 0.45 * sin(p.x * 0.9 + t * (0.13 + 0.04 * fi) + fi * 2.2);
    float gain = (i == 0) ? (0.030 + 0.070 * mid) : (0.018 + 0.045 * level);
    col += (i == 0 ? mint : gold) * ribbon * gain;
  }

  // ---- 流萤：12 颗固定哈希光点缓速上浮，柔核 + 宽晕，高频点亮、击拍齐跃 ----
  for (int i = 0; i < 12; i++) {
    float fi = float(i) + seed;
    float h1 = hash11(fi), h2 = hash11(fi * 1.37 + 7.0);
    float h3 = hash11(fi * 2.11 + 31.0), h4 = hash11(fi * 0.91 + 53.0);
    float x = h1 * 2.0 - 1.0;
    float speed = 0.045 + 0.055 * h2;
    float y = -1.25 + fract(h2 + t * speed) * 2.5;
    x += 0.11 * sin(t * (0.45 + 0.5 * h3) + h4 * 6.28);
    y += beatKick * 0.06 * (0.5 + h3);
    float2 dp = p - float2(x, y);
    float size = 0.016 + 0.020 * h3;
    float g = exp(-dot(dp, dp) / (size * size));          // 清晰的核
    g += 0.38 * exp(-dot(dp, dp) / (size * size * 9.0));  // 梦感宽晕
    float twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * (1.6 + 2.6 * h3) + h2 * 6.28));
    float gain = (0.085 + 0.17 * treble + 0.08 * beatKick) * mix(0.55, 1.0, twinkle) * liveMix;
    col += mix(gold, mint, h4) * g * gain;
  }

  // ---- 经典 LED 频谱地板：24 列 × 8 层彩色方块，块数随律动增减 ----
  // bars = buffer(1) 的 24 个 float（PulseFrame.bars，log 分布 32Hz–9kHz，0...1）
  float barRow = (p.x + 1.0) * 12.0; // 24 列铺满横向，每列 ~7px
  int bi = int(floor(barRow));
  if (bi >= 0 && bi < 24) {
    float h = clamp(bars[bi], 0.0, 1.0);
    float fx = fract(barRow);
    const float rows = 8.0;
    const float pitch = 0.062; // 层距（NDC）：实心方块 ~3px + 空隙，168px 下清晰
    float litF = h * rows;     // 点亮层数（连续值，方块随其跨过整数逐格增减）
    float rowF = (p.y + 1.0) / pitch;
    int row = int(floor(rowF));
    if (row >= 0 && row < int(rows)) {
      float fy = fract(rowF);
      float2 d = float2(abs(fx - 0.5), abs(fy - 0.5));
      float sq = (1.0 - smoothstep(0.28, 0.45, d.x)) * (1.0 - smoothstep(0.28, 0.45, d.y));
      float isLit = (float(row) < litF) ? 1.0 : 0.0;
      float isTop = isLit * (1.0 - smoothstep(0.3, 0.7, abs(float(row) - (ceil(litF) - 1.0))));
      // 五颜六色：横向扫过彩虹，纵向每层错相，再随时间极缓慢流转
      float hue = fract(float(bi) * 0.0375 + float(row) * 0.055 + t * 0.008 + seed * 0.11);
      float3 bcol = hsv2rgb(float3(hue, 0.60, 1.0));
      bcol = mix(bcol, float3(1.0), 0.16);         // 提亮成糖果感，贴近梦境色板
      bcol = mix(bcol, float3(1.0), isTop * 0.40); // 顶层块更亮，像峰值 LED
      float3 ghost = mix(lilac, float3(0.5, 0.55, 0.62), 0.35);
      float pres = smoothstep(0.015, 0.10, h); // 完全静默时整列隐去
      float kick = 1.0 + beatKick * 0.4;
      col += bcol * sq * isLit * (0.20 + 0.10 * h) * pres * liveMix * kick;
      col += ghost * sq * (1.0 - isLit) * 0.022 * pres * liveMix; // 未点亮的暗格
      // 顶端柔光晕：方块堆雾化收边，保住梦幻感
      float topY = -1.0 + ceil(litF) * pitch;
      float above = max(p.y - topY, 0.0);
      float halo = (1.0 - smoothstep(0.28, 0.45, d.x)) * exp(-above * above / (2.0 * 0.034 * 0.034));
      col += mix(bcol, float3(1.0), 0.4) * halo * (0.045 + 0.06 * h) * pres * liveMix * kick;
    }
  }

  // ---- 径向频谱环：24 段频谱绕唱片一圈（左右镜像，低频在底、高频在顶）----
  // 与 LED 地板共用 buffer(1) 的 24 段数据和同一套彩虹配色。
  // 内圈 0.81 贴着唱片边缘（盘半径 ~0.74 NDC，hover+呼吸最大 ~0.79），底部 ±50° 让位给 LED 地板
  {
    float rr = length(p);
    if (rr > 0.79 && rr < 0.94) {
      float sa = fract((atan2(p.y, p.x) + 1.5707963) / 6.2831853); // 0 = 6 点方向，逆时针
      float dBottom = min(sa, 1.0 - sa); // 0 在 6 点方向，0.5 在 12 点方向
      float uu = min(abs(sa - 0.5) * 48.0, 23.999); // 0 顶 → 24 底（镜像，顶部留缺口）
      float rbi = floor(uu);
      float rfu = fract(uu);
      float h = clamp(bars[int(rbi)], 0.0, 1.0);
      float wedge = 1.0 - smoothstep(0.30, 0.47, abs(rfu - 0.5));
      wedge *= smoothstep(0.05, 0.16, dBottom); // 底部弧段隐去，不压 LED 地板
      float rt = (rr - 0.81) / max(h * 0.11, 0.02);
      float body = smoothstep(0.0, 0.18, rt) * (1.0 - smoothstep(0.62, 1.0, rt));
      float base = exp(-pow((rr - 0.81) / 0.045, 2.0));
      float hue = rbi * 0.0375 + t * 0.008 + seed * 0.11;
      float3 rcol = hsv2rgb(float3(hue, 0.60, 1.0));
      rcol = mix(rcol, float3(1.0), 0.16);
      col += rcol * (body * (0.05 + 0.10 * h) + base * 0.035 * h)
           * wedge * liveMix * (1.0 + beatKick * 0.3);
    }
  }

  // ---- 节拍：全场柔光涌动（不用扩散圆环——小尺寸下圆环显脏）----
  col += mix(mint, gold, 0.35) * beatSwell * (0.020 + 0.10 * bass) * exp(-d2 / 1.1);

  // 压角加深，夜色四周沉下去、中央梦境浮出来
  col *= 1.0 - 0.20 * dot(p, p);

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
