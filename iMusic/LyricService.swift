import Foundation

// MARK: - 歌词行（滚动显示用）
struct LyricLine: Hashable {
  var time: Double // 秒
  var text: String
}

enum LrcParser {
  /// 解析 [mm:ss.xx] 行；去逐字标签 <ms,dur> / (s,dur,?)；去空行；按时间排序
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
      text = text.replacingOccurrences(of: #"<\d+,\d+>"#, with: "", options: .regularExpression)
      text = text.replacingOccurrences(of: #"\(\d+,\d+(,\d+)?\)"#, with: "", options: .regularExpression)
      text = text.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      out.append(LyricLine(time: m * 60 + s + ms, text: text))
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

// MARK: - 官站歌词兜底（自定义源不给 lyric 时用）
// kw: m.kuwo.cn songinfoandlrc（明文 JSON，对标 lyric.js 注释版 getLyric）
// kg: lyrics.kugou.com search+download（仅 lrc 明文；krc 需 decodeKrc，MVP 跳过）
// wy: eapi /api/song/lyric/v1（签名复用 wyEapiParams）
// tx: QRC 二进制加密格式，官站兜底极其复杂（需解密 QRC），MVP 仅走自定义源
// mg: MRC 加密格式，官站兜底需解密 MRC，MVP 仅走自定义源
enum OfficialLyric {
  /// 按源分发（注册表 SourceRegistry 持有各源 lyric 闭包；此处仅保留各源实现）
  static func fetch(_ song: MusicInfo) async throws -> LyricInfo? {
    guard let fn = SourceRegistry.capability(id: song.source.rawValue)?.lyric else { return nil }
    return try await fn(song)
  }

  static func kw(_ song: MusicInfo) async -> LyricInfo? {
    do {
      let json = try await iMusicHttp.getJSON("http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=\(song.songmid)") as? [String: Any]
      guard let data = json?["data"] as? [String: Any],
            let list = data["lrclist"] as? [[String: Any]], !list.isEmpty else { return nil }
      var lines: [String] = []
      for item in list {
        let t: Double
        if let n = item["time"] as? Double { t = n }
        else if let n = item["time"] as? Int { t = Double(n) }
        else if let s = item["time"] as? String { t = Double(s) ?? 0 }
        else { continue }
        let text = ((item["lineLyric"] as? String) ?? (item["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        lines.append("[\(iMusicSign.mmss(Int(t))).\(String(format: "%02d", Int((t.truncatingRemainder(dividingBy: 1)) * 100)))]\(text)")
      }
      guard !lines.isEmpty else { return nil }
      return LyricInfo(lyric: lines.joined(separator: "\n"))
    } catch { return nil }
  }

  static func kg(_ song: MusicInfo) async -> LyricInfo? {
    do {
      let hash = song.extra?["hash"] ?? ""
      let secs = Int(song.extra?["intervalSecs"] ?? "") ?? 0
      let q = song.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
      let headers = ["KG-RC": "1", "KG-THash": "expand_search_manager.cpp:852736169:451",
                     "User-Agent": "KuGou2012-9020-ExpandSearchManager"]
      let s = try await iMusicHttp.getJSON("http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=\(q)&hash=\(hash)&timelength=\(secs)&lrctxt=1", headers: headers) as? [String: Any]
      guard let c = (s?["candidates"] as? [[String: Any]])?.first,
            let lid = c["id"], let key = c["accesskey"] else { return nil }
      let fmt = ((c["krctype"] as? Int) == 1 && (c["contenttype"] as? Int) != 1) ? "krc" : "lrc"
      guard fmt == "lrc" else { return nil } // krc 需 decodeKrc（异或解码），MVP 跳过
      let d = try await iMusicHttp.getJSON("http://lyrics.kugou.com/download?ver=1&client=pc&id=\(lid)&accesskey=\(key)&fmt=lrc&charset=utf8", headers: headers) as? [String: Any]
      guard let b64 = d?["content"] as? String, let data = Data(base64Encoded: b64),
            let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
      return LyricInfo(lyric: text)
    } catch { return nil }
  }

  static func wy(_ song: MusicInfo) async throws -> LyricInfo? {
    let params = try iMusicSign.wyEapiParams(url: "/api/song/lyric/v1", object: [
      "id": Int(song.songmid) ?? 0, "cp": false, "tv": 0, "lv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0,
    ])
    let json = try await iMusicHttp.postForm("https://interface3.music.163.com/eapi/song/lyric/v1", form: ["params": params],
      headers: ["User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/60.0.3112.90 Safari/537.36",
                "origin": "https://music.163.com"]) as? [String: Any]
    guard let code = json?["code"] as? Int, code == 200,
          let lrc = (json?["lrc"] as? [String: Any])?["lyric"] as? String, !lrc.isEmpty else { return nil }
    func fix(_ s: String?) -> String? {
      s?.replacingOccurrences(of: #"\[(\d{2}:\d{2}):(\d{2})\]"#, with: "[$1.$2]", options: .regularExpression)
    }
    return LyricInfo(lyric: fix(lrc) ?? lrc,
                     tlyric: fix((json?["tlyric"] as? [String: Any])?["lyric"] as? String),
                     rlyric: fix((json?["romalrc"] as? [String: Any])?["lyric"] as? String))
  }
}

// MARK: - 封面兜底（对标各源 pic.js；搜索自带图的源直接用搜索图）
enum OfficialPic {
  static func fetch(_ song: MusicInfo) async -> String? {
    if let fn = SourceRegistry.capability(id: song.source.rawValue)?.pic {
      return await fn(song)
    }
    return song.picUrl // 无专属封面逻辑的源：透传搜索自带图（tx/wy/mg）
  }

  /// 酷我：对标 kw/pic.js artistpicserver，直出 http URL 文本
  static func kwPic(_ song: MusicInfo) async -> String? {
    if let u = song.picUrl, !u.isEmpty { return u }
    if let url = URL(string: "http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=\(song.songmid)"),
       let (data, _) = try? await URLSession.shared.data(from: url),
       let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       s.hasPrefix("http") { return s }
    return nil
  }
}
