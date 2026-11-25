import Foundation

// MARK: - 逐字歌词（ALWordLyric）
//
// 只读 submodule 参考（extensions/ 与 any-listen/ 均只读，不改动）：
//   extensions/online-metadata/src/onlineResource/wy/lyric.ts:20-197  parseTools（YRC 解析）
//   extensions/online-metadata/src/onlineResource/wy/lyric.ts:199-212 fixTimeLabel（2/3 位时间标签修正）
//   extensions/online-metadata/src/onlineResource/wy/lyric.ts:215-242 getLyric（eapi 取词）
//   extensions/online-metadata/src/onlineResource/mg/lyric.ts:6-106     MRC 解析 / 翻译 / 取词
//   extensions/online-metadata/src/onlineResource/mg/utils/mrc.ts:1-97  TEA 解密 + UTF-16LE 解码
//
// 输出契约：`lyric` 为普通 LRC `[mm:ss.mmm]词`；`lxlyric`/`awlyric` 为逐字版
//   `[mm:ss.mmm]<relMs,dur>词<relMs,dur>词…`，relMs 相对行首，dur 为词时长（毫秒）。
//   该格式可被 LrcParser.parseWordSync 直接消费（<a,b> 词段）。
//   `awlyric` = online-metadata 扩展返回的逐字字段；`lxlyric` 同步写入以复用现有 UI。

enum ALWordLyric {
  // MARK: - 对外 API

  /// 网易云逐字歌词（YRC）。eapi 取词 → parseTools 同款解析。
  /// - Returns: 有逐字数据时返回完整 LyricInfo；无数据/解析失败抛 ALSourceError（由 enrich 兜住）。
  static func wyLyric(music: MusicInfo) async throws -> LyricInfo? {
    let json = try await fetchWyJSON(music)

    func field(_ key: String) -> String? {
      guard let s = (json[key] as? [String: Any])?["lyric"] as? String, !s.isEmpty else { return nil }
      return ALFormat.decodeName(s)
    }

    // 对齐 wy/lyric.ts:228：code != 200 或 lrc 为空视为失败
    guard field("lrc") != nil else {
      throw ALSourceError.invalidResponse("网易逐字歌词缺失")
    }

    // wy/lyric.ts:199-212：修正 [mm:ss:cs] 与罗马音 3 位/尾 0 标签
    let fixed = fixTimeLabel(field("lrc"), field("tlyric"), field("romalrc"))
    let info = parseWy(ylrc: field("yrc"), ytlrc: field("ytlrc"), yromalrc: field("yromalrc"),
                       lrc: fixed.lrc, tlrc: fixed.tlrc, rlrc: fixed.romalrc)
    guard !info.lyric.isEmpty else {
      throw ALSourceError.invalidResponse("网易逐字歌词解析失败")
    }
    return info
  }

  /// 咪咕逐字歌词（MRC）：缺 mrcUrl 时先走 musicDetail 补取（对齐 mg/lyric.ts:87）
  static func mgLyric(music: MusicInfo) async throws -> LyricInfo? {
    let resolved = await ALMgDetail.ensureLyricInfo(music) ?? music
    guard let mrcUrl = resolved.extra?["mrcUrl"], !mrcUrl.isEmpty else { return nil }

    let (data, response) = try await ALHttp.getRaw(mrcUrl, headers: Self.mgHeaders, requireOK: true)
    guard response.statusCode == 200, !data.isEmpty else {
      throw ALSourceError.invalidResponse("咪咕 MRC 获取失败")
    }
    // mg/utils/mrc.ts:94-97 decrypt()：HTTP 响应为十六进制文本，TEA 解出 UTF-16LE 明文
    guard let plain = ALCrypto.teaDecrypt(data, keyHex: Self.mrcKeys),
          let text = mrcPlainText(plain), !text.isEmpty else {
      throw ALSourceError.invalidResponse("咪咕 MRC 解密失败")
    }
    let parsed = parseMrc(text)
    guard !parsed.lyric.isEmpty else {
      throw ALSourceError.invalidResponse("咪咕 MRC 解析失败")
    }

    // mg/lyric.ts:78-81 getTrc：翻译走明文 GET，失败不影响逐字歌词
    var tlyric: String? = nil
    if let trcUrl = music.extra?["trcUrl"], !trcUrl.isEmpty,
       let (trcData, trcResp) = try? await ALHttp.getRaw(trcUrl, headers: Self.mgHeaders, requireOK: true),
       trcResp.statusCode == 200,
       let trcText = String(data: trcData, encoding: .utf8), !trcText.isEmpty {
      tlyric = ALFormat.decodeName(trcText)
    }

    let wordLyric = parsed.awlyric.isEmpty ? nil : parsed.awlyric
    return LyricInfo(lyric: parsed.lyric, tlyric: tlyric, rlyric: nil,
                     lxlyric: wordLyric, awlyric: wordLyric)
  }

  /// 逐字增强入口：仅 .wy/.mg 尝试；任一失败或无逐字数据则原样返回传入歌词。
  static func enrich(_ lyric: LyricInfo, from source: MusicSource, music: MusicInfo) async -> LyricInfo {
    let parsed: LyricInfo?
    switch source {
    case .wy: parsed = try? await wyLyric(music: music)
    case .mg: parsed = try? await mgLyric(music: music)
    default: return lyric
    }
    guard var result = parsed, !result.lyric.isEmpty,
          let word = result.awlyric, !word.isEmpty else { return lyric }

    // 逐字结果缺翻译时沿用原歌词已有翻译，避免覆盖造成译文丢失
    if result.tlyric?.isEmpty != false { result.tlyric = lyric.tlyric }
    if result.rlyric?.isEmpty != false { result.rlyric = lyric.rlyric }
    if result.lxlyric?.isEmpty != false { result.lxlyric = word }
    return result
  }

  // MARK: - 网易云（wy/lyric.ts 逐行移植）

  /// eapi /api/song/lyric/v1。eapi 为 POST form（ALHttp 无 postForm），
  /// 复用 iMusicHttp.postForm —— 与 AnyListenWy.musicLyric 完全相同的 endpoint / params / headers。
  /// 除 lrc/tlyric/romalrc 外额外读取 yrc/ytlrc/yromalrc 三个逐字字段。
  private static func fetchWyJSON(_ music: MusicInfo) async throws -> [String: Any] {
    let params = try iMusicSign.wyEapiParams(url: "/api/song/lyric/v1", object: [
      "id": Int(music.songmid) ?? 0, "cp": false, "tv": 0, "lv": 0, "rv": 0,
      "kv": 0, "yv": 0, "ytv": 0, "yrv": 0,
    ])
    let json = try await iMusicHttp.postForm(
      "https://interface3.music.163.com/eapi/song/lyric/v1",
      form: ["params": params],
      headers: ["User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
                "origin": "https://music.163.com"]) as? [String: Any]
    guard let json, ALHttp.int(json["code"]) == 200 else {
      throw ALSourceError.invalidResponse("网易逐字歌词响应异常")
    }
    return json
  }

  /// wy/lyric.ts:40-51 msFormat。pad3=false 时毫秒截为 2 位（旧式标签）。
  private static func msFormat(_ timeMs: Double, pad3: Bool = true) -> String {
    guard timeMs.isFinite else { return "" }
    let total = Int(max(0, timeMs))
    let ms = total % 1000
    let seconds = total / 1000
    let m = seconds / 60
    let s = seconds % 60
    let msText = pad3 ? String(format: "%03d", ms) : String(format: "%02d", ms / 10)
    return String(format: "[%02d:%02d.%@]", m, s, msText)
  }

  /// wy/lyric.ts:91-107 parseHeaderInfo：JSON 行 `{"t":ms,"c":[{"tx":"…"}]}` → 时间标签 + 文本。
  private static func parseHeaderInfo(_ str: String?) -> [String]? {
    guard let str else { return nil }
    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\r", with: "")
    guard !trimmed.isEmpty else { return nil }

    let hasMs3 = firstMatch(of: #"\[\d+:\d+\.\d{3}\]"#, in: trimmed) != nil
    let hasMs2 = firstMatch(of: #"\[\d+:\d+\.\d{2}\]"#, in: trimmed) != nil
    let isPad3 = hasMs3 || !hasMs2 // wy/lyric.ts:95

    return trimmed.components(separatedBy: "\n").map { line in
      guard line.hasPrefix("{\"") else { return line }
      guard let data = line.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let t = ALHttp.double(obj["t"]) else { return "" }
      let text = (obj["c"] as? [[String: Any]])?.compactMap { $0["tx"] as? String }.joined() ?? ""
      let tag = msFormat(t, pad3: isPad3)
      return tag.isEmpty ? "" : tag + text
    }
  }

  /// wy/lyric.ts:52-90 parseLyric：
  /// `[start,end]词(start,dur,x)词…` → 普通 lyric + 逐字 awlyric（`<rel,dur>词`）。
  private static func parseYrcLines(_ lines: [String]) -> (lyric: String, awlyric: String) {
    let linePattern = #"^\[(\d+),\d+\]"#
    let wordPattern = #"\(\d+,\d+,\d+\)"#
    let wordCapturePattern = #"\((\d+),(\d+),\d+\)"#

    var lrcLines: [String] = []
    var awLines: [String] = []
    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespaces)
      let ns = line as NSString
      guard let lineMatch = firstMatch(of: linePattern, in: line) else {
        // wy/lyric.ts:60-63：[offset:…] 行两种歌词都保留
        if line.hasPrefix("[offset") {
          lrcLines.append(line)
          awLines.append(line)
        }
        continue
      }
      let startMs = Int(group(lineMatch, 1, in: ns)) ?? 0
      let stamp = msFormat(Double(startMs))
      guard !stamp.isEmpty else { continue }

      let wordsRange = NSRange(location: lineMatch.range.upperBound,
                               length: ns.length - lineMatch.range.upperBound)
      let words = ns.substring(with: wordsRange)
      let wordsNS = words as NSString

      // 普通歌词：剥掉全部 (a,b,c) 词时间戳
      let plain = replace(pattern: wordPattern, in: words, with: "")
      lrcLines.append(stamp + plain)

      // 逐字歌词：(start,dur,x) → <max(start-lineStart,0),dur>；词文本在时间戳之后
      let tags = matches(of: wordCapturePattern, in: words)
      guard !tags.isEmpty else { continue }
      var newWords = ""
      for (i, tag) in tags.enumerated() {
        let wordStart = Int(group(tag, 1, in: wordsNS)) ?? 0
        let dur = group(tag, 2, in: wordsNS)
        let rel = max(wordStart - startMs, 0) // wy/lyric.ts:79
        let textStart = tag.range.upperBound
        let textEnd = i + 1 < tags.count ? tags[i + 1].range.lowerBound : wordsNS.length
        let text = textEnd >= textStart
          ? wordsNS.substring(with: NSRange(location: textStart, length: textEnd - textStart)) : ""
        newWords += "<\(rel),\(dur)>" + text
      }
      awLines.append(stamp + newWords)
    }
    return (lrcLines.joined(separator: "\n"), awLines.joined(separator: "\n"))
  }

  /// wy/lyric.ts:108-115 getIntv：`mm:ss.cc` / `hh:mm:ss.ccc` → 毫秒（parseInt 原样，2 位即 34ms）。
  private static func getIntv(_ interval: String) -> Int {
    guard !interval.isEmpty else { return 0 }
    let normalized = interval.contains(".") ? interval : interval + ".0"
    var parts = normalized.components(separatedBy: CharacterSet(charactersIn: ":."))
    while parts.count < 3 { parts.insert("0", at: 0) }
    let m = Int(parts[0]) ?? 0
    let s = Int(parts[1]) ?? 0
    let ms = Int(parts[2]) ?? 0
    return m * 3_600_000 + s * 1000 + ms
  }

  /// wy/lyric.ts:116-146 fixTimeTag：翻译/音译行按 ±100ms 就近吸附原文时间标签。
  private static func fixTimeTag(_ lrc: String, _ target: String) -> String {
    let pattern = #"^\[([\d:.]+)\]"#
    var candidates = lrc.components(separatedBy: "\n")
    var result: [String] = []

    for line in target.components(separatedBy: "\n") {
      let ns = line as NSString
      guard let m = firstMatch(of: pattern, in: line) else { continue }
      let rest = ns.substring(from: m.range.upperBound)
      guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      let t1 = getIntv(group(m, 1, in: ns))

      var temp: [String] = []
      while !candidates.isEmpty {
        let candidate = candidates.removeFirst()
        let cns = candidate as NSString
        guard let cm = firstMatch(of: pattern, in: candidate) else { continue } // 无时间标签行丢弃
        let t2 = getIntv(group(cm, 1, in: cns))
        if abs(t1 - t2) < 100 {
          let tag = cns.substring(with: cm.range(at: 0))
          let joined = (tag + rest).trimmingCharacters(in: .whitespaces)
          if !joined.isEmpty { result.append(joined) }
          break
        }
        temp.append(candidate)
      }
      candidates = temp + candidates
    }
    return result.joined(separator: "\n")
  }

  /// wy/lyric.ts:199-212 fixTimeLabel：修正 [mm:ss:cs] → [mm:ss.cs]，
  /// 并在主歌词/翻译变更时同步修正罗马音 3 位毫秒标签与尾 0。
  private static func fixTimeLabel(_ lrc: String?, _ tlrc: String?, _ romalrc: String?)
    -> (lrc: String?, tlrc: String?, romalrc: String?) {
    var newLrc = lrc
    var newTlrc = tlrc
    var newRomalrc = romalrc
    if let original = lrc, !original.isEmpty {
      let fixedLrc = replace(pattern: #"\[(\d{2}:\d{2}):(\d{2})]"#, in: original, with: "[$1.$2]")
      let fixedTlrc = tlrc.map { replace(pattern: #"\[(\d{2}:\d{2}):(\d{2})]"#, in: $0, with: "[$1.$2]") }
      if fixedLrc != original || fixedTlrc != tlrc {
        newLrc = fixedLrc
        newTlrc = fixedTlrc
        newRomalrc = romalrc.map {
          let a = replace(pattern: #"\[(\d{2}:\d{2}):(\d{2,3})]"#, in: $0, with: "[$1.$2]")
          return replace(pattern: #"\[(\d{2}:\d{2}\.\d{2})0]"#, in: a, with: "[$1]")
        }
      }
    }
    return (newLrc, newTlrc, newRomalrc)
  }

  /// wy/lyric.ts:147-196 parse：优先 YRC（yrc/ytlrc/yromalrc），否则退回明文 lrc/tlrc/rlrc。
  private static func parseWy(ylrc: String?, ytlrc: String?, yromalrc: String?,
                              lrc: String?, tlrc: String?, rlrc: String?) -> LyricInfo {
    if let ylrc, let lines = parseHeaderInfo(ylrc), !lines.isEmpty {
      let parsed = parseYrcLines(lines)
      var tlyric = ""
      var rlyric = ""
      if let ytlrc, let trans = parseHeaderInfo(ytlrc) {
        tlyric = fixTimeTag(parsed.lyric, trans.joined(separator: "\n"))
      }
      if let yromalrc, let roma = parseHeaderInfo(yromalrc) {
        rlyric = fixTimeTag(parsed.lyric, roma.joined(separator: "\n"))
      }
      let headers = lines.filter { firstMatch(of: #"^\[[\d:.]+\]"#, in: $0) != nil }
        .joined(separator: "\n")
      let lyric = headers.isEmpty ? parsed.lyric : headers + "\n" + parsed.lyric
      let word = parsed.awlyric.isEmpty ? nil : parsed.awlyric
      return LyricInfo(lyric: lyric, tlyric: tlyric.isEmpty ? nil : tlyric,
                       rlyric: rlyric.isEmpty ? nil : rlyric, lxlyric: word, awlyric: word)
    }

    func join(_ s: String?) -> String? {
      guard let lines = parseHeaderInfo(s) else { return nil }
      let text = lines.joined(separator: "\n")
      return text.isEmpty ? nil : text
    }
    return LyricInfo(lyric: join(lrc) ?? "", tlyric: join(tlrc), rlyric: join(rlrc),
                     lxlyric: nil, awlyric: nil)
  }

  // MARK: - 咪咕（mg/lyric.ts + mg/utils/mrc.ts 逐行移植）

  /// mg/lyric.ts:55-63 getText 的公共请求头。
  private static let mgHeaders: [String: String] = [
    "Referer": "https://app.c.nf.migu.cn/",
    "User-Agent": "Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36",
    "channel": "0146921",
  ]

  /// mg/utils/mrc.ts:6-16 keyArr（十进制大整数）→ 16 位十六进制字符串。
  /// ALCrypto.teaDecrypt(_:keyHex:) 按此顺序消费 9 个 64 位 key（与扩展 keyArr 一一对应）。
  private static let mrcKeys: [String] = [
    "006100720061006B", // 27303562373562475
    "0040006C0061006B", // 18014862372307051
    "0051003300320031", // 22799692160172081
    "0079006D006F0063", // 34058940340699235
    "006E006F00640069", // 30962724186095721
    "0061006900740067", // 27303523720101991
    "006100690074006E", // 27303523720101998
    "006F00610068006E", // 31244139033526382
    "0067006E00690074", // 28992395054481524
  ]

  /// mg/utils/mrc.ts:47-51 longArrToString：明文为 UTF-16LE；兼容 ALCrypto 返回 UTF-8 文本的情形。
  private static func mrcPlainText(_ data: Data) -> String? {
    let even = data.count % 2 == 0 ? data : Data(data.dropLast())
    if let s = String(data: even, encoding: .utf16LittleEndian), s.contains("[") {
      return s.replacingOccurrences(of: "\u{FEFF}", with: "")
    }
    return String(data: data, encoding: .utf8)
  }

  /// mg/lyric.ts:12-53 parseLyric：
  /// `[start,end]词(start,dur)词…` → 普通 lyric + 逐字 awlyric（`<start-lineStart,dur>词`）。
  private static func parseMrc(_ str: String) -> (lyric: String, awlyric: String) {
    let text = str.replacingOccurrences(of: "\r", with: "")
    let linePattern = #"^\s*\[(\d+),\d+\]"#
    let wordPattern = #"\(\d+,\d+\)"#
    let wordCapturePattern = #"\((\d+),(\d+)\)"#

    var lrcLines: [String] = []
    var awLines: [String] = []
    for line in text.components(separatedBy: "\n") where line.utf16.count >= 6 {
      let ns = line as NSString
      guard let lineMatch = firstMatch(of: linePattern, in: line) else { continue }

      let startMs = Int(group(lineMatch, 1, in: ns)) ?? 0
      let stamp = msFormat(Double(startMs)) // mg/lyric.ts:24-32 同款 [mm:ss.mmm]

      let wordsRange = NSRange(location: lineMatch.range.upperBound,
                               length: ns.length - lineMatch.range.upperBound)
      let words = ns.substring(with: wordsRange)
      let wordsNS = words as NSString

      let plain = replace(pattern: wordPattern, in: words, with: "")
      lrcLines.append(stamp + plain)

      // mg/lyric.ts:44-46：split 不 shift —— 词文本位于时间戳之前
      let tags = matches(of: wordCapturePattern, in: words)
      guard !tags.isEmpty else { continue }
      var newWords = ""
      for (i, tag) in tags.enumerated() {
        let wordStart = Int(group(tag, 1, in: wordsNS)) ?? 0
        let dur = group(tag, 2, in: wordsNS)
        let rel = wordStart - startMs // mg/lyric.ts:42：不截断负值
        let textStart = i == 0 ? 0 : tags[i - 1].range.upperBound
        let textEnd = tag.range.lowerBound
        let token = textEnd >= textStart
          ? wordsNS.substring(with: NSRange(location: textStart, length: textEnd - textStart)) : ""
        newWords += "<\(rel),\(dur)>" + token
      }
      awLines.append(stamp + newWords)
    }
    return (lrcLines.joined(separator: "\n"), awLines.joined(separator: "\n"))
  }

  // MARK: - 正则小工具（局部创建，避免 Swift 6 下跨并发共享可变 Foundation 对象）

  private static func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern)
  }

  private static func matches(of pattern: String, in text: String) -> [NSTextCheckingResult] {
    regex(pattern).matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
  }

  private static func firstMatch(of pattern: String, in text: String) -> NSTextCheckingResult? {
    regex(pattern).firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
  }

  private static func replace(pattern: String, in text: String, with template: String) -> String {
    let re = regex(pattern)
    let ns = text as NSString
    return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                       withTemplate: template)
  }

  private static func group(_ match: NSTextCheckingResult, _ index: Int, in ns: NSString) -> String {
    let r = match.range(at: index)
    return r.location == NSNotFound ? "" : ns.substring(with: r)
  }
}
