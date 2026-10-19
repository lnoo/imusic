import AVFoundation
import Accelerate
import Foundation
import QuartzCore

// MARK: - 随心听律动信号源
// 旁路二次解码当前播放项（AVAssetReader → 单声道 Float 采样环），按名义播放头
// 每帧取 4096 窗做 vDSP FFT，产出 低/中/高 频能量与节拍事件，驱动随心听卡片
// 的 Metal shader 背景与 3D 角色。播放链路完全不变（仍 AVPlayer → 系统输出），
// 不装 tap、不碰输出路由。流式格式旁路解码失败 / 数据不足时自动退回模拟律动
// （约 104 BPM 近似信号），观感连续不断档。
//
// 线程模型：主 Actor 60fps 采样发布；`PulseBus` 是唯一跨线程载体（NSLock 快照），
// Metal/SceneKit 渲染回调与旁路解码线程都只通过 bus 交换数据。
// 音量策略（已确认）：视觉跟随播放器输出包络，设 0 即完全静止。

/// 每帧信号快照（值类型，跨线程拷贝）
struct PulseFrame: Sendable {
  var bass: Float = 0 // 0...1 低频（鼓点/贝斯）
  var mid: Float = 0 // 0...1 中频（人声/旋律）
  var treble: Float = 0 // 0...1 高频（镲/空气感）
  var level: Float = 0 // 0...1 整体响度
  var beatAge: Double = 10 // 距上次击拍的秒数（驱动弹跳衰减）
  var beatIndex: Int = 0 // 击拍计数（角色动作触发）
  var morphIndex: Int = 0 // 换形态计数（表情/配色切换）
  var live: Bool = false // 有真实音频驱动
  var active: Bool = false // 正在播放（含模拟兜底）
  var disabled: Bool = false // 卡片禁用态 → 视觉降饱和
  var error: Bool = false // 失败态 → 视觉偏红
  var hover: Bool = false
}

/// 跨线程快照总线
final class PulseBus: @unchecked Sendable {
  static let shared = PulseBus()
  private let lock = NSLock()
  private var _frame = PulseFrame()
  /// 名义播放头（帧，单调）：主线程推进，旁路解码线程按它控制解码节奏
  private var _cursorFrames: Double = 0
  /// 播放项代次：attach 递增，旧解码线程见代次变化即自弃
  private var _generation = 0

  private init() {}

  var snapshot: PulseFrame {
    lock.lock(); defer { lock.unlock() }
    return _frame
  }

  func mutate(_ body: (inout PulseFrame) -> Void) {
    lock.lock(); defer { lock.unlock() }
    body(&_frame)
  }

  var cursorFrames: Double {
    get { lock.lock(); defer { lock.unlock() }; return _cursorFrames }
    set { lock.lock(); defer { lock.unlock() }; _cursorFrames = newValue }
  }

  var generation: Int {
    lock.lock(); defer { lock.unlock() }
    return _generation
  }

  func bumpGeneration() -> Int {
    lock.lock(); defer { lock.unlock() }
    _generation += 1
    _cursorFrames = 0
    return _generation
  }
}

@MainActor
final class AudioPulse {
  static let shared = AudioPulse()
  static let bus = PulseBus.shared

  private let sampleRate = 44_100.0
  private let windowCount = 4096
  private let ring = SampleRing(capacity: Int(44_100) * 2)

  private var samplerTimer: Timer?
  private var lastTickTime: TimeInterval = 0
  private var cursor: Double = 0 // 名义播放头（帧）
  private var window = [Float](repeating: 0, count: 4096)
  private var hann: [Float]
  private var dftSetup: vDSP_DFT_Setup?
  private var reIn = [Float](repeating: 0, count: 4096)
  private var imIn = [Float](repeating: 0, count: 4096)
  private var reOut = [Float](repeating: 0, count: 4096)
  private var imOut = [Float](repeating: 0, count: 4096)
  private var bassHistory = [Float](repeating: 0, count: 48) // ~4s 低频均值窗
  private var bandBaseline: [Float] = [0, 0, 0, 0] // 各带对数能量慢基线（AGC，首窗播种）
  private var baselinesSeeded = false
  private var bassHistoryIndex = 0
  private var simPhase: Double = 0
  private var liveFor: TimeInterval = 999 // 距最近一次真实数据（秒）
  private var lastBeatTime: TimeInterval = 0
  private var lastMorphTime: TimeInterval = 0
  /// PlayerStore 注入的播放态（避免与 AppState 形成引用环）
  private var playing = false
  /// 播放器音量 0...1；设 0 或直接停播 → 视觉致静
  private var gate: Double = 1

  private init() {
    let n = Double(windowCount)
    hann = (0..<windowCount).map { Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / n)) }
    dftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(windowCount), .FORWARD)
    startSampler()
  }

  // MARK: 对外接口（PlayerStore / 卡片调用）

  /// 新解析出播放地址：断开旧旁路，起新喂入线程
  func attach(urlString: String) {
    ring.reset()
    cursor = 0
    liveFor = 999
    baselinesSeeded = false
    let gen = PulseBus.shared.bumpGeneration()
    guard let url = URL(string: urlString) else { return }
    DispatchQueue(label: "imusic.audiopulse.feed", qos: .userInitiated).async { [ring] in
      Self.feed(assetURL: url, gen: gen, ring: ring)
    }
  }

  /// 停止/失败：立即静默
  func detach() {
    ring.reset()
    cursor = 0
    _ = PulseBus.shared.bumpGeneration()
  }

  /// 播放器音量/播放态注入
  func setPlaying(_ on: Bool) { playing = on }
  func setGate(_ volume: Double) { gate = max(0, min(1, volume)) }

  /// 卡片状态联动（禁用降饱和 / 失败飘红）
  func setVisual(disabled: Bool, error: Bool) {
    PulseBus.shared.mutate { $0.disabled = disabled; $0.error = error }
  }

  func setHovered(_ hovered: Bool) {
    PulseBus.shared.mutate { $0.hover = hovered }
  }

  // MARK: 采样循环（60fps）

  private func startSampler() {
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick(CACurrentMediaTime()) }
    }
    RunLoop.main.add(timer, forMode: .common)
    samplerTimer = timer
    lastTickTime = CACurrentMediaTime()
  }

  private func tick(_ now: TimeInterval) {
    let dt = min(max(now - lastTickTime, 1.0 / 240.0), 0.1)
    lastTickTime = now
    let active = playing && gate > 0.02

    // 播放头只在播放时推进；环里没解码到的部分自然补零
    if active { cursor += dt * sampleRate }
    PulseBus.shared.cursorFrames = cursor
    let start = Int(cursor) - windowCount
    let realFrames = ring.read(from: start, into: &window)
    liveFor = (realFrames > windowCount / 2) ? 0 : liveFor + dt
    let live = active && liveFor < 1.2

    let (bassRaw, midRaw, trebleRaw, levelRaw) = live ? analyzeWindow() : (0, 0, 0, 0)

    var bassV = bassRaw
    var midV = midRaw
    var trebleV = trebleRaw
    var levelV = levelRaw
    var beat = false

    if live {
      // 节拍：低频瞬态显著高于近期均值
      bassHistory[bassHistoryIndex] = bassRaw
      bassHistoryIndex = (bassHistoryIndex + 1) % bassHistory.count
      let mean = bassHistory.reduce(0, +) / Float(bassHistory.count)
      if bassRaw > mean * 1.38 + 0.03, now - lastBeatTime > 0.22 { beat = true }
    } else if active {
      // 模拟兜底：~104 BPM 近似律动（旁路解码不可用 / 数据没跟上时）
      simPhase += dt * 104.0 / 60.0
      if simPhase >= 1 { simPhase -= 1; beat = true }
      let t = Float(now)
      bassV = max(0, 0.55 + 0.4 * sin(t * 2.1))
      midV = max(0, 0.38 + 0.28 * sin(t * 1.37 + 1.0))
      trebleV = max(0, 0.24 + 0.22 * sin(t * 2.83 + 2.0))
      levelV = max(0, 0.42 + 0.28 * sin(t * 1.7 + 0.5))
    }

    let gateF = Float(gate)
    let atk: Float = 1 - exp(-Float(dt) * 22) // 快起
    let rel: Float = 1 - exp(-Float(dt) * 3.6) // 慢落
    func smoothed(_ current: Float, _ target: Float) -> Float {
      let t = target * gateF
      return current + (t - current) * (t > current ? atk : rel)
    }
    PulseBus.shared.mutate { f in
      f.bass = smoothed(f.bass, bassV)
      f.mid = smoothed(f.mid, midV)
      f.treble = smoothed(f.treble, trebleV)
      f.level = smoothed(f.level, levelV)
      f.beatAge += dt
      f.live = live
      f.active = active
    }

    if beat {
      lastBeatTime = now
      PulseBus.shared.mutate { f in
        f.beatIndex += 1
        f.beatAge = 0
      }
      // 约每 2–3 拍换一次形态，最短间隔 3.5s
      if now - lastMorphTime > 3.5, Int.random(in: 0..<3) > 0 {
        lastMorphTime = now
        PulseBus.shared.mutate { $0.morphIndex += 1 }
      }
    } else if now - lastMorphTime > 10, Int.random(in: 0..<120) == 0 {
      // 空闲时的“不时变个样”
      lastMorphTime = now
      PulseBus.shared.mutate { $0.morphIndex += 1 }
    }
  }

  /// FFT 当前窗 → 三频段归一化能量 + 整体响度
  private func analyzeWindow() -> (Float, Float, Float, Float) {
    // 实信号 → 复数 DFT：虚部置 0，加窗就地完成
    vDSP_vmul(window, 1, hann, 1, &reIn, 1, vDSP_Length(windowCount))
    guard let dftSetup else { return (0, 0, 0, 0) }
    vDSP_DFT_Execute(dftSetup, reIn, imIn, &reOut, &imOut)

    // bin ≈ 10.8Hz：低频 11–215 / 中频 215–1508 / 高频 1.5k–9kHz / 整体
    func logE(_ from: Int, _ to: Int) -> Float {
      var sumSq: Float = 0
      for k in from..<to {
        sumSq += reOut[k] * reOut[k] + imOut[k] * imOut[k]
      }
      return 10 * log10(max(sumSq / Float(to - from), 1e-9))
    }
    // 每带对数域 AGC：与慢基线比出相对动态，任何响度/码率的源都稳定
    var out = [logE(1, 20), logE(20, 140), logE(140, 836), logE(1, 836)]
    if !baselinesSeeded {
      bandBaseline = out
      baselinesSeeded = true
      return (0.45, 0.45, 0.45, 0.45) // 起播中性，避免头几秒被压制
    }
    for i in 0..<4 {
      let e = out[i]
      let baseline = bandBaseline[i]
      let k: Float = e > baseline ? 0.06 : 0.008 // 快跟慢放
      bandBaseline[i] += (e - baseline) * k
      out[i] = min(1, max(0, 0.45 + (e - baseline) / 12))
    }
    return (out[0], out[1], out[2], out[3])
  }
}

// MARK: - 采样环（写：旁路解码线程；读：主线程）

final class SampleRing: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer: [Float]
  private let capacity: Int
  private(set) var framesWritten = 0 // 已写入总帧数（单调）

  init(capacity: Int) {
    self.capacity = capacity
    buffer = [Float](repeating: 0, count: capacity)
  }

  func append(_ data: UnsafePointer<Float>, _ count: Int) {
    guard count > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    // 超长只保留最新 capacity 帧
    var src = data
    var remaining = count
    if count > capacity {
      src += count - capacity
      remaining = capacity
    }
    while remaining > 0 {
      let pos = framesWritten % capacity
      let chunk = min(remaining, capacity - pos)
      for i in 0..<chunk { buffer[pos + i] = src[i] }
      src += chunk
      framesWritten += chunk
      remaining -= chunk
    }
  }

  /// 读取绝对区间 [from, from+n)；界外补零，返回真实提供的帧数
  @discardableResult
  func read(from: Int, into dst: inout [Float]) -> Int {
    lock.lock()
    defer { lock.unlock() }
    let lo = max(from, Swift.max(framesWritten - capacity, 0))
    let hi = Swift.min(from + dst.count, framesWritten)
    var provided = 0
    for i in 0..<dst.count {
      let absIdx = from + i
      if absIdx >= lo && absIdx < hi {
        dst[i] = buffer[absIdx % capacity]
        provided += 1
      } else {
        dst[i] = 0
      }
    }
    return provided
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    framesWritten = 0
  }
}

// MARK: - 旁路解码（后台队列，阻塞式 AVAssetReader）

extension AudioPulse {
  /// 二次解码到采样环。节奏预算：领先播放头不超过 1.5s，避免起播瞬间
  /// 把整首歌解完冲 CPU；数据跟不上时由上层自动落模拟律动。
  nonisolated fileprivate static func feed(assetURL: URL, gen: Int, ring: SampleRing) {
    let rate = 44_100.0
    let warm = Int(rate * 0.5) // 预解码半秒
    let ahead = Int(rate * 1.5)
    // 注意：不能传 PreferPreciseDurationAndTiming=false，实测会导致 tracks 同步取空
    let asset = AVURLAsset(url: assetURL)
    guard
      let track = asset.tracks(withMediaType: .audio).first,
      let reader = try? AVAssetReader(asset: asset)
    else { return }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsBigEndianKey: false,
      AVNumberOfChannelsKey: 1,
      AVSampleRateKey: rate,
    ])
    reader.add(output)
    guard reader.startReading() else { return }

    /// 解一帧进环；false = 解码器无更多数据
    func decodeOne() -> Bool {
      guard let sample = output.copyNextSampleBuffer() else { return false }
      defer { CMSampleBufferInvalidate(sample) }
      var listStorage = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
      )
      var block: CMBlockBuffer?
      let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample,
        bufferListSizeNeededOut: nil,
        bufferListOut: &listStorage,
        bufferListSize: MemoryLayout<AudioBufferList>.size,
        blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil,
        flags: 0,
        blockBufferOut: &block
      )
      guard status == noErr, let data = listStorage.mBuffers.mData else { return true }
      let frames = CMSampleBufferGetNumSamples(sample)
      guard frames > 0 else { return true }
      data.bindMemory(to: Float.self, capacity: Int(frames)).withMemoryRebound(to: Float.self, capacity: Int(frames)) { ptr in
        ring.append(ptr, frames)
      }
      return true
    }

    var warmed = 0
    while reader.status == .reading, warmed < warm {
      guard decodeOne() else { break }
      warmed = ring.framesWritten
      if PulseBus.shared.generation != gen { break }
    }
    while reader.status == .reading {
      if PulseBus.shared.generation != gen { break }
      let backlog = ring.framesWritten - Int(PulseBus.shared.cursorFrames)
      if backlog < ahead {
        guard decodeOne() else { break }
      } else {
        Thread.sleep(forTimeInterval: 0.1)
      }
    }
    if reader.status == .reading { reader.cancelReading() }
  }
}
