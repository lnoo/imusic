import Foundation
import Translation
import Observation
import NaturalLanguage

// MARK: - 系统机翻兜底（LyricTranslator）
//
// 对「无源自带翻译（kg 源 / 冷门外文歌）且原文非中文」的歌词，用 macOS 系统
// Translation 框架逐行译成简体中文，结果按歌缓存成 LRC 字符串，供 LyricView 复用
// mergeTranslation 按时间戳对齐显示（与源自带 tlyric 走同一条渲染链路）。
//
// 设计约束：
//  · 仅当 player.lyric 无 tlyric 时才启用机翻（有源翻译直接显示源翻译，不重复翻）
//  · 只翻非中文歌词（中文歌跳过，避免无意义开销）
//  · 单例 + Observation：LyricView 在 body 读取 currentCached/isTranslating 即可自动重绘
//  · 会话复用（首次使用可能触发语言包下载/在线翻译），按行文本去重，避免重复翻译副歌

@Observable @MainActor
final class LyricTranslator {
  static let shared = LyricTranslator()

  /// 歌 id → 已翻译的 LRC（"时间戳]译文" 逐行）；命中即直接使用，不再机翻
  private var cache: [String: String] = [:]
  /// 正在机翻的歌（幂等：同一首歌不并发/不重复翻）
  private var inFlight: Set<String> = []
  /// 当前生效歌曲 id（LyricView 读取 currentCached 时据此联动，触发观察）
  private(set) var activeSongID: String?
  /// 翻译框架会话是否可用/已初始化（供开关按钮显隐判断）
  private(set) var available = false
  /// 是否正在机翻（供视图显示"翻译中…"）
  private(set) var isTranslating = false

  /// 目标简体中文
  private let targetLang = Locale.Language(identifier: "zh-Hans")

  private init() {}

  /// 当前歌曲的机翻结果（LRC 字符串），无结果返回 nil
  var currentCached: String? {
    guard let id = activeSongID else { return nil }
    return cache[id]
  }

  /// 歌词发生变化且满足「无源翻译 + 非中文」时触发机翻（幂等）。
  /// - Parameters:
  ///   - songID: 当前歌曲唯一标识（player.current.id）
  ///   - base: 解析后的歌词行（lrc/逐字均可），用于取时间戳与判语言
  ///   - hasSourceTlyric: 是否已有源自带翻译（有则不机翻）
  func ensureTranslation(songID: String, base: [LyricLine], hasSourceTlyric: Bool) async {
    guard !hasSourceTlyric, !base.isEmpty else { return }
    guard cache[songID] == nil, !inFlight.contains(songID) else { return }
    let fullText = base.map(\.text).joined()
    guard !LrcParser.isChinese(fullText) else { return } // 中文歌不翻

    activeSongID = songID
    inFlight.insert(songID)
    isTranslating = true
    available = true
    defer {
      inFlight.remove(songID)
      isTranslating = false
    }

    // 检测歌词主语言，作为翻译源语言（macOS27 API 需显式指定已安装源语言）
    guard let sourceLang = Self.detectLanguage(fullText) else { return }
    let session = TranslationSession(installedSource: sourceLang, target: targetLang)

    // 按行文本去重：副歌重复行只翻一次
    var memo: [String: String] = [:]
    var out: [String] = []
    for line in base {
      let src = line.text.trimmingCharacters(in: .whitespaces)
      guard !src.isEmpty else { continue }
      let translated: String
      if let hit = memo[src] {
        translated = hit
      } else {
        do {
          let r = try await session.translate(src)
          translated = r.targetText.trimmingCharacters(in: .whitespaces)
        } catch {
          continue // 单行失败跳过，不影响其余
        }
        memo[src] = translated
      }
      guard !translated.isEmpty, translated != src else { continue }
      out.append("[\(Self.lrcTime(line.time))]\(translated)")
    }
    guard !out.isEmpty else { return }
    cache[songID] = out.joined(separator: "\n")
  }

  /// 用 NaturalLanguage 检测歌词主语言，映射为 Locale.Language（ISO 639-1 语言码）
  private static func detectLanguage(_ text: String) -> Locale.Language? {
    guard !text.isEmpty else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let dominant = recognizer.dominantLanguage?.rawValue else { return nil }
    return Locale.Language(identifier: dominant)
  }

  /// 秒 → LRC 时间戳 [mm:ss.xxx]（毫秒精度，与 base 行时间精确对齐）
  private static func lrcTime(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    let ms = Int((seconds - floor(seconds)) * 1000)
    return String(format: "%02d:%02d.%03d", m, s, ms)
  }
}