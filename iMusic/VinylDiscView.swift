import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - 随心听中心：旋转唱片
// 与 MascotSpriteView 互为备选的中心主体（在 HomeView 随心听卡片里二选一）：
//  - 圆盘：程序化唱纹 + 圆形封面（双层交叉淡化）+ 主轴孔，播放时缓速旋转（12s/圈）。
//    60Hz tick 手动转角而非 CA 无限动画：暂停即停、续播无缝、seek 不跳变；
//  - 唱针：播放落盘、暂停/禁用抬起（弹性摆动）；
//  - 律动：击拍呼吸缩放、hover 放大；封面缺失/加载中 → 渐变标贴 + 音符兜底。
// 与 PulseShaderView 同款约定：点击穿透、不进无障碍树、状态自走 PulseBus，
// 封面 URL 由 SwiftUI 侧（player.current?.picUrl）经 updateNSView 注入。

struct VinylDiscView: NSViewRepresentable {
  var coverURL: String?

  func makeCoordinator() -> VinylDiscController { VinylDiscController() }

  func makeNSView(context: Context) -> NSView {
    let view = PassThroughDiscView(frame: .zero)
    view.wantsLayer = true
    context.coordinator.attach(to: view)
    context.coordinator.setCoverURL(coverURL)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.setCoverURL(coverURL)
  }

  func dismantleNSView(_ nsView: NSView, coordinator: VinylDiscController) {
    coordinator.teardown()
  }
}

private final class PassThroughDiscView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private enum CoverCache {
  static let cache = NSCache<NSString, CGImage>()
}

@MainActor
final class VinylDiscController: NSObject {
  private weak var host: NSView?

  // 层树：outer（呼吸/hover 缩放）→ disc（旋转）→ vinyl（盘底+唱纹）/ coverA/coverB（外环带
  // 封面，图纹唱片样式）/ grooveOverlay（封面上的半透明唱纹）/ label（中心标贴）/ spindle；
  // armGroup（唱针，不随盘转，绕支点摆动）
  private let outerLayer = CALayer()
  private let discLayer = CALayer()
  private let vinylLayer = CALayer()
  private let grooveOverlay = CALayer()
  private let labelLayer = CALayer()
  private let coverA = CALayer()
  private let coverB = CALayer()
  private let spindleLayer = CALayer()
  private let armGroup = CALayer()
  private let armShape = CAShapeLayer()
  private let armWeight = CAShapeLayer()

  private var timer: Timer?
  private var lastUpdate: TimeInterval = CACurrentMediaTime()
  private var rotation: CGFloat = 0 // 累计转角（度）
  private var frontIsA = false // 封面交叉淡化的前台层
  private var coverURLString: String?
  private var loadToken = 0 // 防串图：旧任务回调按 token 丢弃
  private var lastBroken = -1

  // 布局缓存
  private var lastBounds: NSRect?
  private var armOnDisc = false

  // MARK: 装配

  func attach(to view: NSView) {
    host = view
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for l in [outerLayer, discLayer, vinylLayer, labelLayer, coverA, coverB, spindleLayer, armGroup] {
      l.actions = nil
      l.masksToBounds = false
    }
    view.layer?.addSublayer(outerLayer)
    outerLayer.addSublayer(discLayer)
    discLayer.addSublayer(vinylLayer)
    discLayer.addSublayer(coverA)
    discLayer.addSublayer(coverB)
    discLayer.addSublayer(grooveOverlay)
    discLayer.addSublayer(labelLayer)
    discLayer.addSublayer(spindleLayer)
    outerLayer.addSublayer(armGroup)
    armGroup.addSublayer(armShape)
    armGroup.addSublayer(armWeight)
    // 唱针/平衡锤允许探出宿主边界（SwiftUI 那侧还有 6pt padding 缓冲），避免被裁
    view.layer?.masksToBounds = false
    for c in [coverA, coverB] {
      c.masksToBounds = true
      c.contentsGravity = .resizeAspectFill
      c.opacity = 0
    }
    labelLayer.masksToBounds = true
    vinylLayer.masksToBounds = true
    grooveOverlay.masksToBounds = true
    armShape.lineCap = .round
    armShape.strokeColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor
    armShape.fillColor = NSColor.clear.cgColor
    armWeight.fillColor = NSColor(calibratedWhite: 0.30, alpha: 1).cgColor
    CATransaction.commit()
    layout()
    showArm(animated: false)

    let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func teardown() {
    timer?.invalidate()
    timer = nil
    host = nil
  }

  // MARK: 封面注入（SwiftUI 侧 player.current?.picUrl）

  func setCoverURL(_ urlString: String?) {
    guard urlString != coverURLString else { return }
    coverURLString = urlString
    loadToken += 1
    let token = loadToken
    guard let raw = urlString, let url = URL(string: raw),
          url.scheme?.hasPrefix("http") == true else {
      showFallback()
      return
    }
    if let cached = CoverCache.cache.object(forKey: raw as NSString) {
      applyCover(cached, token: token)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 512,
            ] as CFDictionary) else { return }
      CoverCache.cache.setObject(cg, forKey: raw as NSString)
      DispatchQueue.main.async { [weak self] in
        self?.applyCover(cg, token: token)
      }
    }
  }

  private func applyCover(_ cg: CGImage, token: Int) {
    guard token == loadToken, host != nil else { return }
    let incoming = frontIsA ? coverB : coverA
    let outgoing = frontIsA ? coverA : coverB
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.45)
    incoming.contents = cg
    incoming.opacity = 1
    outgoing.opacity = 0
    CATransaction.commit()
    frontIsA.toggle()
  }

  private func showFallback() {
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.3)
    coverA.opacity = 0
    coverB.opacity = 0
    CATransaction.commit()
  }

  // MARK: 60Hz tick：旋转 / 呼吸 / 唱针 / 破损态

  private func tick() {
    guard let host else { return }
    if host.bounds != lastBounds {
      lastBounds = host.bounds
      layout()
    }
    let now = CACurrentMediaTime()
    let dt = min(max(now - lastUpdate, 1.0 / 240.0), 0.1)
    lastUpdate = now
    let f = PulseBus.shared.snapshot

    // 旋转：小尺寸盘按观感取 12s/圈（30°/s）；拟真 33⅓ RPM 是 200°/s，在 97px 盘上显得飞快
    if f.active {
      rotation = (rotation + CGFloat(dt) * 30).truncatingRemainder(dividingBy: 360)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    discLayer.transform = CATransform3DMakeRotation(rotation * .pi / 180, 0, 0, 1)
    let kick = CGFloat(exp(-f.beatAge * 5.0)) * (f.live ? 1 : 0.6)
    var s: CGFloat = 1 + 0.035 * kick
    if f.hover { s *= 1.03 } // 大盘下 hover 收敛，避免盖住频谱环内圈
    outerLayer.transform = CATransform3DMakeScale(s, s, 1)
    CATransaction.commit()

    // 唱针：播放落盘，暂停/禁用抬起
    let on = f.active && !f.disabled && !f.error
    if on != armOnDisc {
      armOnDisc = on
      showArm(animated: true)
    }
    // 破损态：降饱和
    let brokenBit = (f.disabled || f.error) ? 1 : 0
    if brokenBit != lastBroken {
      lastBroken = brokenBit
      let filter = CIFilter(name: "CIColorControls")
      filter?.setValue(brokenBit == 1 ? 0.15 : 1.0, forKey: kCIInputSaturationKey)
      discLayer.filters = filter.map { [$0] } ?? []
      discLayer.opacity = brokenBit == 1 ? 0.85 : 1
    }
  }

  private func showArm(animated: Bool) {
    CATransaction.begin()
    if animated {
      CATransaction.setAnimationDuration(0.55)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
    } else {
      CATransaction.setDisableActions(true)
    }
    let deg: CGFloat = armOnDisc ? 0 : 40
    armGroup.transform = CATransform3DMakeRotation(deg * .pi / 180, 0, 0, 1)
    CATransaction.commit()
  }

  // MARK: 布局（跟随宿主 bounds）

  private func layout() {
    guard let host else { return }
    let b = host.bounds
    let D = min(b.width, b.height) * 0.80
    let cx = b.midX
    let cy = b.midY + b.height * 0.02
    let discFrame = CGRect(x: cx - D / 2, y: cy - D / 2, width: D, height: D)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outerLayer.frame = b
    discLayer.frame = discFrame
    vinylLayer.frame = discLayer.bounds
    vinylLayer.contents = Self.grooveImage(side: max(D * 2, 64))
    vinylLayer.cornerRadius = D / 2

    let labelD = D * 0.48
    labelLayer.frame = CGRect(x: (D - labelD) / 2, y: (D - labelD) / 2, width: labelD, height: labelD)
    labelLayer.cornerRadius = labelD / 2
    labelLayer.contents = Self.fallbackLabel(side: max(labelD * 2, 48))
    // 封面：占满整盘（圆形裁切），中心被标贴盖住 → 只露出外环带（图纹唱片样式）
    for c in [coverA, coverB] {
      c.frame = discLayer.bounds
      c.cornerRadius = D / 2
    }
    // 封面上的半透明唱纹：让外环带保持黑胶质感
    grooveOverlay.frame = discLayer.bounds
    grooveOverlay.contents = Self.grooveRingsImage(side: max(D * 2, 64))
    grooveOverlay.cornerRadius = D / 2
    let sd = max(D * 0.055, 6)
    spindleLayer.frame = CGRect(x: (D - sd) / 2, y: (D - sd) / 2, width: sd, height: sd)
    spindleLayer.cornerRadius = sd / 2
    spindleLayer.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
    spindleLayer.borderColor = NSColor(calibratedWhite: 0.38, alpha: 1).cgColor
    spindleLayer.borderWidth = 1

    // 唱针：支点在盘右上，播放姿态指向盘缘（armShape 按该姿态绘制，摆角相对它）。
    // 几何收在宿主边界内（平衡锤半径也算上），大盘时不探出卡片
    let pivot = CGPoint(x: cx + D * 0.42, y: cy + D * 0.44)
    let target = CGPoint(x: cx + D * 0.24, y: cy - D * 0.12)
    armGroup.frame = b
    armGroup.anchorPoint = CGPoint(x: pivot.x / max(b.width, 1), y: pivot.y / max(b.height, 1))
    armGroup.position = pivot
    armGroup.bounds = b
    let dx = target.x - pivot.x, dy = target.y - pivot.y
    let armPath = CGMutablePath()
    armPath.move(to: pivot)
    armPath.addLine(to: target)
    armShape.path = armPath
    armShape.lineWidth = max(D * 0.04, 2.5)
    let dir = CGPoint(x: dx / hypot(dx, dy), y: dy / hypot(dx, dy))
    let weightCenter = CGPoint(x: pivot.x - dir.x * D * 0.11, y: pivot.y - dir.y * D * 0.11)
    let wr = D * 0.055
    armWeight.path = CGPath(ellipseIn: CGRect(x: weightCenter.x - wr, y: weightCenter.y - wr,
                                              width: wr * 2, height: wr * 2), transform: nil)
    CATransaction.commit()
  }

  // MARK: 程序化素材

  /// 唱片盘面：深灰径向渐变 + 细密唱纹 + 对向高光 + 外缘描边（2x 分辨率，一次绘制缓存于层）
  private static func grooveImage(side: CGFloat) -> CGImage? {
    let s = side
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    defer { img.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
    let c = CGPoint(x: s / 2, y: s / 2)
    let r = s / 2

    let base = NSGradient(colors: [
      NSColor(calibratedWhite: 0.105, alpha: 1),
      NSColor(calibratedWhite: 0.045, alpha: 1),
      NSColor(calibratedWhite: 0.075, alpha: 1),
    ])
    base?.draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: s, height: s)), angle: -90)

    // 唱纹：从标贴外缘到盘缘的同心细圈
    let grooveCount = 26
    let lw = max(s / 560, 0.7)
    for i in 0..<grooveCount {
      let t = CGFloat(i) / CGFloat(grooveCount - 1)
      let rr = r * (0.52 + 0.46 * t)
      let alpha: CGFloat = (i % 2 == 0) ? 0.075 : 0.04
      ctx.setStrokeColor(CGColor(gray: 1, alpha: alpha))
      ctx.setLineWidth(lw)
      ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
    }
    // 轨分隔圈（略亮，模拟分曲间隙）
    for t in [0.33, 0.66] {
      let rr = r * (0.52 + 0.46 * t)
      ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.11))
      ctx.setLineWidth(lw * 1.6)
      ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
    }
    // 对向高光：两团柔光模拟反光弧
    ctx.saveGState()
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s), transform: nil))
    ctx.clip()
    let sheenColors = [
      CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
      CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ]
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: sheenColors as CFArray, locations: [0, 1]) {
      for pt in [CGPoint(x: s * 0.30, y: s * 0.74), CGPoint(x: s * 0.70, y: s * 0.26)] {
        ctx.drawRadialGradient(g, startCenter: pt, startRadius: 0,
                               endCenter: pt, endRadius: s * 0.45, options: [])
      }
    }
    ctx.restoreGState()
    // 外缘描边
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    ctx.setLineWidth(max(s / 280, 1))
    ctx.strokeEllipse(in: CGRect(x: 1, y: 1, width: s - 2, height: s - 2))

    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
  }

  /// 封面外环带上的半透明唱纹（透明底，只画纹路 + 轻微高光），让图纹唱片仍有黑胶质感
  private static func grooveRingsImage(side: CGFloat) -> CGImage? {
    let s = side
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    defer { img.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
    let c = CGPoint(x: s / 2, y: s / 2)
    let r = s / 2
    let grooveCount = 22
    let lw = max(s / 560, 0.7)
    for i in 0..<grooveCount {
      let t = CGFloat(i) / CGFloat(grooveCount - 1)
      let rr = r * (0.27 + 0.71 * t)
      ctx.setStrokeColor(CGColor(gray: 0, alpha: (i % 2 == 0) ? 0.16 : 0.09))
      ctx.setLineWidth(lw)
      ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
    }
    for t in [0.36, 0.70] {
      let rr = r * (0.27 + 0.71 * t)
      ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.20))
      ctx.setLineWidth(lw * 1.6)
      ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
    }
    // 顶部一道柔光弧，压住封面亮度、呼应盘面反光
    let sheenColors = [
      CGColor(gray: 1, alpha: 0.12),
      CGColor(gray: 1, alpha: 0.0),
    ]
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: sheenColors as CFArray, locations: [0, 1]) {
      let pt = CGPoint(x: s * 0.32, y: s * 0.72)
      ctx.drawRadialGradient(g, startCenter: pt, startRadius: 0,
                             endCenter: pt, endRadius: s * 0.42, options: [])
    }
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
  }

  /// 兜底标贴：深绿径向渐变 + 金环 + 白色音符（无封面/加载中显示）
  private static func fallbackLabel(side: CGFloat) -> CGImage? {
    let s = side
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    defer { img.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
    let colors = [
      CGColor(red: 0.13, green: 0.34, blue: 0.24, alpha: 1),
      CGColor(red: 0.05, green: 0.12, blue: 0.09, alpha: 1),
    ]
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                          locations: [0, 1]) {
      ctx.drawRadialGradient(g, startCenter: CGPoint(x: s * 0.5, y: s * 0.62), startRadius: 0,
                             endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.55, options: [])
    }
    ctx.setStrokeColor(CGColor(red: 1, green: 0.83, blue: 0.45, alpha: 0.5))
    ctx.setLineWidth(max(s * 0.02, 1))
    ctx.strokeEllipse(in: CGRect(x: s * 0.10, y: s * 0.10, width: s * 0.80, height: s * 0.80))
    if let sym = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: s * 0.30, weight: .medium))?
      .withSymbolConfiguration(.init(paletteColors: [.white])) {
      let sz = sym.size
      sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
  }
}
