import AppKit
import CoreImage
import Metal
import MetalKit
import QuartzCore
import simd
import SwiftUI

// MARK: - 随心听卡片视觉层
// 当前中心主体为 VinylDiscView（VinylDiscView.swift，旋转唱片）；
// 本文件的 MascotSpriteView（流萤精灵宠物）保留为备选中心，
// 在 HomeView 随心听卡片里二选一替换即可。
// 两层 NSViewRepresentable 叠放在 168×168 方形卡片里：
//  1. PulseShaderView —— Metal 背景：「雾海流萤·梦境」，星云雾 + 梦境光斑 +
//     极光缎带 + 流萤 + 经典 LED 频谱地板（24 列 × 8 层彩色方块），随律动呼吸
//     （低频呼吸/中频雾光/高频闪烁/节拍涌动/逐段频谱弹跳）；
//  2. MascotSpriteView —— 社区素材「流萤」精灵宠物：待机呼吸 / 播放小跑 /
//     击拍 squash&stretch 弹跳 / 切歌招手跳跃，纯 2D 帧动画（Core Animation）。
// 两者都不接收 SwiftUI 状态参数：创建一次后靠总线自走，避免状态刷新重建视图。

// MARK: - Metal shader 背景

/// 与 Shaders.metal 里的 Uniforms 逐字节对应（5 × float4，共 80 字节，buffer(0)）；
/// 另有 24 段频谱经 buffer(1) 传入（PulseFrame.bars，逐 float 排布，无对齐歧义）
struct PulseUniforms {
  var colA: SIMD4<Float> // 强调色（rgb + 亮度增益）
  var colB: SIMD4<Float> // 深色底
  var a: SIMD4<Float> // time, bass, mid, treble
  var b: SIMD4<Float> // level, beatAge, hover, live
  var c: SIMD4<Float> // disabled, error, seed, strength
}

/// 纯装饰层的点击穿透：SwiftUI 的 allowsHitTesting 拦不住 AppKit 子视图自身的 hitTest，
/// 必须让 MTKView / SCNView 返回 nil，卡片按钮才能收到点击。
private final class PassThroughMTKView: MTKView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct PulseShaderView: NSViewRepresentable {
  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> MTKView {
    let view = PassThroughMTKView()
    view.device = context.coordinator.device
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.preferredFramesPerSecond = 60
    view.delegate = context.coordinator
    return view
  }

  func updateNSView(_ nsView: MTKView, context: Context) {}

  func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
    nsView.delegate = nil
    nsView.isPaused = true
  }

  final class Coordinator: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private let seed = Float.random(in: 0..<100)

    override init() {
      device = MTLCreateSystemDefaultDevice()
      super.init()
      guard let device,
            let library = try? device.makeDefaultLibrary(bundle: .main),
            let vert = library.makeFunction(name: "pulse_vertex"),
            let frag = library.makeFunction(name: "pulse_fragment") else { return }
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = vert
      desc.fragmentFunction = frag
      desc.colorAttachments[0].pixelFormat = .bgra8Unorm
      pipeline = try? device.makeRenderPipelineState(descriptor: desc)
      queue = device.makeCommandQueue()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
      guard let pipeline, let drawable = view.currentDrawable,
            let pass = view.currentRenderPassDescriptor,
            let buffer = queue?.makeCommandBuffer() else { return }
      guard let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

      let f = PulseBus.shared.snapshot
      // 状态 → 配色：播放中主色更亮，禁用降强度，失败交给 shader 里混红
      var intensity: Float = f.error ? 0.55 : (f.disabled ? 0.30 : (f.active ? 1.0 : 0.5))
      if f.live { intensity = max(intensity, 0.75) }
      let accent = simd_make_float4(0.114, 0.843, 0.376, 1) // Theme.accent
      let base = simd_make_float4(0.050, 0.092, 0.072, 1) // 深底（比 Theme.bg 略抬绿）
      var u = PulseUniforms(
        colA: accent,
        colB: base,
        a: SIMD4(Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 600)), f.bass, f.mid, f.treble),
        b: SIMD4(f.level, Float(min(f.beatAge, 4)), f.hover ? 1 : 0, f.live ? 1 : 0),
        c: SIMD4(f.disabled ? 1 : 0, f.error ? 1 : 0, seed, intensity)
      )
      enc.setRenderPipelineState(pipeline)
      enc.setFragmentBytes(&u, length: MemoryLayout<PulseUniforms>.stride, index: 0)
      // 频谱地板数据：24 段（PulseFrame.bars）走 buffer(1)
      var barData = f.bars
      if barData.count != PulseFrame.barCount {
        barData = [Float](repeating: 0, count: PulseFrame.barCount)
      }
      enc.setFragmentBytes(&barData, length: barData.count * MemoryLayout<Float>.stride, index: 1)
      enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      enc.endEncoding()
      buffer.present(drawable)
      buffer.commit()
    }
  }
}

// MARK: - 流萤精灵宠物（Codex pet 社区素材，非 3D）

/*
 角色来自 awesome-codex-pet 社区图库（MIT 仓库托管），素材许可 CC BY-NC 4.0：
 "Firefly / 流萤"（《崩坏：星穹铁道》同人造型），作者 legeling，
 https://codexpet.top/pets/firefly--lingxiaotian
 精灵图集 1536×1872 = 8 列 × 9 行（v1 标准），每格 192×208，逐行一个动作。
 帧时长取自官方 webp 预览的 ANMF chunk。行映射经 alpha 轮廓逐帧比对确认。
*/

/// 图集里的动作行（v1 布局）
private enum PetAction {
  case idle, running, wave, jump, failed

  var row: Int {
    switch self {
    case .idle: return 0
    case .wave: return 3
    case .jump: return 4
    case .failed: return 5
    case .running: return 7
    }
  }
  var frameCount: Int {
    switch self {
    case .idle, .running: return 6
    case .wave: return 4
    case .jump: return 5
    case .failed: return 8
    }
  }
  /// 每帧毫秒（官方预览 ANMF 解析结果）
  var delays: [Double] {
    switch self {
    case .idle: return [280, 110, 110, 140, 140, 320]
    case .running: return [120, 120, 120, 120, 120, 220]
    case .wave: return [140, 140, 140, 280]
    case .jump: return [140, 140, 140, 140, 280]
    case .failed: return [140, 140, 140, 140, 140, 140, 140, 240]
    }
  }
}

private final class PassThroughSpriteView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var wantsUpdateLayer: Bool { false }
}

struct MascotSpriteView: NSViewRepresentable {
  func makeCoordinator() -> SpritePetController { SpritePetController() }

  func makeNSView(context: Context) -> NSView {
    let view = PassThroughSpriteView(frame: .zero)
    view.wantsLayer = true
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  func dismantleNSView(_ nsView: NSView, coordinator: SpritePetController) {
    coordinator.teardown()
  }
}

/// 60Hz 主线程 tick：读 PulseBus 推进帧动画 + 事件（击拍弹跳 / 切歌打招呼）。
/// 帧图只是 layer.contents 指针切换，弹跳交给 Core Animation，CPU 开销可忽略。
final class SpritePetController: NSObject, @unchecked Sendable {
  private weak var host: NSView?
  private let frameLayer = CALayer() // 最内：精灵帧图（弹跳 transform）
  private let outerLayer = CALayer() // 外层：hover 缩放
  private var actions: [PetAction: (frames: [CGImage], delays: [Double])] = [:]
  private var loaded = false

  private var timer: Timer?
  private var lastUpdate: TimeInterval = CACurrentMediaTime()
  private var current: PetAction?
  private var base: PetAction = .idle
  private var frameIndex = 0
  private var frameClock: Double = 0
  private var oneShot = false
  private var holdLast = false
  private var nextEvent: PetAction = .wave
  private var lastBeat = -1
  private var lastMorph = -1
  private var lastHover = false
  private var lastVisual = -1
  private var lastFrame: CGImage?

  // MARK: 装配

  func attach(to view: NSView) {
    host = view
    outerLayer.anchorPointZ = 0
    outerLayer.actions = nil
    frameLayer.contentsGravity = .resizeAspect
    frameLayer.anchorPoint = CGPoint(x: 0.5, y: 0) // 底部为轴：挤压贴地、跳跃离地
    outerLayer.addSublayer(frameLayer)
    view.layer?.addSublayer(outerLayer)
    loadAtlas()
    layout()
    show(.idle) // 开机待机，等总线状态接管

    let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func teardown() {
    timer?.invalidate()
    timer = nil
    host = nil
  }

  private func loadAtlas() {
    guard let url = Bundle.main.url(forResource: "firefly_spritesheet", withExtension: "webp"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
    let cw = atlas.width / 8
    let ch = atlas.height / 9
    for action in [PetAction.idle, .running, .wave, .jump, .failed] {
      var frames: [CGImage] = []
      for c in 0..<action.frameCount {
        if let cell = atlas.cropping(to: CGRect(x: c * cw, y: action.row * ch, width: cw, height: ch)) {
          frames.append(cell)
        }
      }
      if frames.count == action.frameCount { actions[action] = (frames, action.delays) }
    }
    loaded = !actions.isEmpty
  }

  // MARK: 动画核心

  private func show(_ action: PetAction, oneShot: Bool = false) {
    guard let seq = actions[action] else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    current = action
    frameIndex = 0
    frameClock = 0
    self.oneShot = oneShot
    holdLast = (action == .failed) // 失败：瘫倒一轮后停住，不等下一拍指示
    frameLayer.contents = seq.frames[0]
    lastFrame = seq.frames[0]
    CATransaction.commit()
  }

  private func tick() {
    guard loaded else { return }
    let now = CACurrentMediaTime()
    let dt = min(max(now - lastUpdate, 1.0 / 240.0), 0.1)
    lastUpdate = now
    layoutIfNeeded()

    let f = PulseBus.shared.snapshot
    let broken = f.disabled || f.error

    // 视觉状态：禁用/失败 → 宠物降饱和（背景 shader 已各自处理，这里只管角色）
    let visual = broken ? 1 : 0
    if visual != lastVisual {
      lastVisual = visual
      let filter = CIFilter(name: "CIColorControls")
      filter?.setValue(broken ? 0.15 : 1.0, forKey: kCIInputSaturationKey)
      frameLayer.filters = filter.map { [$0] } ?? []
      frameLayer.opacity = broken ? 0.85 : 1
    }

    // 基础状态机：失败瘫 > 播放奔跑 > 待机呼吸
    let target: PetAction = broken ? .failed : (f.active ? .running : .idle)
    if target != base {
      base = target
      show(target)
    }

    // 事件：击拍弹跳（切帧之外叠加位移动画，不打断循环）
    if f.beatIndex != lastBeat {
      if lastBeat >= 0, !broken, f.active { bounce(bass: f.bass) }
      lastBeat = f.beatIndex
    }
    // 事件：切歌/换形态 → 插播一次招手或跳跃，完播回基础动作
    if f.morphIndex != lastMorph {
      if lastMorph >= 0, f.active, !broken {
        let event = nextEvent
        nextEvent = (event == .wave) ? .jump : .wave
        show(event, oneShot: true)
      }
      lastMorph = f.morphIndex
    }
    // hover：整只宠物轻微放大
    if f.hover != lastHover {
      lastHover = f.hover
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.18)
      outerLayer.setAffineTransform(f.hover ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity)
      CATransaction.commit()
    }

    // 推进帧
    guard let action = current, let seq = actions[action], !seq.frames.isEmpty else { return }
    frameClock += dt * 1000
    while frameClock >= seq.delays[frameIndex] {
      frameClock -= seq.delays[frameIndex]
      frameIndex += 1
      if frameIndex >= seq.frames.count {
        if oneShot { show(base); return }
        if holdLast { frameIndex = seq.frames.count - 1; frameClock = 0; break }
        frameIndex = 0
      }
      let next = seq.frames[frameIndex]
      if next !== lastFrame {
        lastFrame = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = next
        CATransaction.commit()
      }
    }
  }

  /// 节拍弹跳：底部锚点的 squash & stretch，低频越猛跳得越高
  private func bounce(bass: Float) {
    let amp = CGFloat((0.45 + 0.55 * Double(bass)) * 11.0) * 2 // 逻辑点 → layer 坐标（backing 2x 由 scale 无关，直接用点）
    let a = CAKeyframeAnimation(keyPath: "transform")
    func tf(_ y: CGFloat, _ sx: CGFloat, _ sy: CGFloat) -> NSValue {
      var m = CATransform3DMakeScale(sx, sy, 1)
      m = CATransform3DTranslate(m, 0, y, 0)
      return NSValue(caTransform3D: m)
    }
    a.values = [
      NSValue(caTransform3D: CATransform3DIdentity),
      tf(amp * 0.30, 0.96, 1.05),
      tf(amp, 1.02, 0.97),
      tf(amp * 0.45, 1.0, 1.0),
      NSValue(caTransform3D: CATransform3DIdentity),
    ]
    a.keyTimes = [0, 0.22, 0.48, 0.75, 1.0]
    a.duration = 0.34
    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    frameLayer.add(a, forKey: "bounce")
  }

  // MARK: 布局（跟随宿主 bounds，SwiftUI 随时可能改卡片尺寸）

  private var lastBounds: NSRect?
  private func layoutIfNeeded() {
    guard let host, host.bounds != lastBounds else { return }
    lastBounds = host.bounds
    layout()
  }

  private func layout() {
    guard let host else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outerLayer.frame = host.bounds
    // 精灵格 192:208 竖构图，占卡片高度 ~86%，底部留小边
    let targetH = host.bounds.height * 0.86
    let targetW = targetH * (192.0 / 208.0)
    let w = min(targetW, host.bounds.width * 0.92)
    let h = w * (208.0 / 192.0)
    frameLayer.frame = CGRect(
      x: (host.bounds.width - w) / 2,
      y: host.bounds.minY + host.bounds.height * 0.035,
      width: w, height: h
    )
    CATransaction.commit()
  }
}
