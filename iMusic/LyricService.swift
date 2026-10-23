import Foundation

// MARK: - 歌词行（滚动显示用）
struct LyricLine: Hashable {
  var time: Double // 秒
  var text: String
  /// 逐字词段（lxlyric 解析；nil = 无逐字数据）。start/dur 为相对行首的秒数
  var words: [LyricWord]?
}

struct LyricWord: Hashable {
  var text: String
  var start: Double // 相对行首，秒
  var dur: Double   // 秒
}

enum LrcParser {
  /// 解析 [mm:ss.xx] 行；去逐字标签 <a,b> / <a,b,c>（含负数档位，kg-KRC/kw-lrcx 逐字）/
  /// (a,b)（QRC 词对）；去空行；按时间排序
  static func parse(_ lrc: String) -> [LyricLine] {
    let rxp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    var out: [LyricLine] = []
    for raw in lrc.components(separatedBy: .newlines) {
      let line = raw as NSString
      let matches = rxp.matches(in: raw, range: NSRange(location: 0, length: line.length))
      guard let last = matches.last else { continue }
      func g(_ i: Int) -> String { last.range(at: i).location == NSNotFound ? "" : line.substring(with: last.range(at: i)) }
      let m = Double(g(1)) ?? 0, s = Double(g(2)) ?? 0
      var frac = g(3)
      let ms: Double
      if frac.isEmpty { ms = 0 }
      else {
        while frac.count < 3 { frac += "0" }
        ms = (Double(String(frac.prefix(3))) ?? 0) / 1000
      }
      var text = rxp.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: line.length), withTemplate: "")
      text = text.replacingOccurrences(of: #"<-?\d+,\d+(,\d+)?>"#, with: "", options: .regularExpression)
      text = text.replacingOccurrences(of: #"\(\d+,\d+(,\d+)?\)"#, with: "", options: .regularExpression)
      text = text.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      out.append(LyricLine(time: m * 60 + s + ms, text: text))
    }
    return out.sorted { $0.time < $1.time }
  }

  /// 解析逐字歌词（lxlyric）：`[mm:ss.mmm]<a,b>词<a,b,c>词`
  /// a = 词起点毫秒（相对行首），b = 词时长毫秒；第三段（kg-KRC 占位）忽略。
  /// 返回的行带 words，text 为拼接纯文本（无词数据的行不产出）。
  static func parseWordSync(_ lxlyric: String) -> [LyricLine] {
    let lineRxp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    let wordRxp = try! NSRegularExpression(pattern: #"<(-?\d+),(-?\d+)(?:,-?\d+)?>"#)
    var out: [LyricLine] = []
    for raw in lxlyric.components(separatedBy: .newlines) {
      let ns = raw as NSString
      let lineMatches = lineRxp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
      guard let last = lineMatches.last else { continue }
      func g(_ i: Int) -> String { last.range(at: i).location == NSNotFound ? "" : ns.substring(with: last.range(at: i)) }
      let m = Double(g(1)) ?? 0, s = Double(g(2)) ?? 0
      var frac = g(3)
      while frac.count < 3 { frac += "0" }
      let lineTime = m * 60 + s + (Double(frac.prefix(3)) ?? 0) / 1000

      let wordMatches = wordRxp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
      guard !wordMatches.isEmpty else { continue }
      var words: [LyricWord] = []
      for (i, wm) in wordMatches.enumerated() {
        let startMs = Double(ns.substring(with: wm.range(at: 1))) ?? 0
        let durMs = Double(ns.substring(with: wm.range(at: 2))) ?? 0
        let textStart = wm.range.upperBound
        let textEnd = i + 1 < wordMatches.count ? wordMatches[i + 1].range.lowerBound : ns.length
        guard textEnd >= textStart else { continue }
        // 保留原始空白：短语间隔（空格词）参与逐字点亮节奏
        let text = ns.substring(with: NSRange(location: textStart, length: textEnd - textStart))
        guard !text.isEmpty, durMs > 0 else { continue }
        words.append(LyricWord(text: text, start: startMs / 1000, dur: durMs / 1000))
      }
      guard !words.isEmpty else { continue }
      out.append(LyricLine(time: lineTime, text: words.map(\.text).joined(), words: words))
    }
    return out.sorted { $0.time < $1.time }
  }

  static func index(at seconds: Double, in lines: [LyricLine]) -> Int? {
    var idx: Int?
    for (i, l) in lines.enumerated() {
      if l.time <= seconds + 0.15 { idx = i } else { break }
    }
    return idx
  }
}

// MARK: - 官站歌词/封面兜底（any-listen 解析层统一入口）
//
// 全部五源（kw/kg/tx/wy/mg）经 AnyListenResource 资源动作解析：
//   歌词：kg-KRC / tx-QRC / kw-lrcx 三种加密逐字格式在 LyricCodec 解码，
//         wy 走 eapi（原文+翻译+罗马音），mg 走条目自带 lrcUrl 明文直链；
//   封面：各源解析层自带（kg Image / tx albumMid 公式 / wy picUrl / mg img），
//         kw 走 artistpicserver。
// 自定义源声明 lyric/pic 时 PlayerStore 优先走沙箱（不变），此处为官站兜底。

enum OfficialLyric {
  /// 按源分发（AnyListenResource.musicLyric → 各源解析实现）
  static func fetch(_ song: MusicInfo) async throws -> LyricInfo? {
    try await AnyListenResource.musicLyric(source: song.source, music: song)
  }
}

enum OfficialPic {
  static func fetch(_ song: MusicInfo) async -> String? {
    await AnyListenResource.musicPic(source: song.source, music: song)
  }
}
