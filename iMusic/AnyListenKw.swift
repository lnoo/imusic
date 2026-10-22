import Foundation

// MARK: - 酷我解析（AnyListenKw）
//
// 按 any-listen 契约实现的酷我源资源动作（端点已逐个实测）：
//   musicSearch   search.kuwo.cn/r.s（明文 JSON；N_MINFO 音质段逐档解析）
//   topSongs      kbangserver.kuwo.cn 榜单（bangid 参数化；主页目录的真正数据源）
//   lyric         mlyric.kuwo.cn/mobi.s（TP=content → zlib → base64 → "yeelion" XOR，
//                 复刻 lx-music kw/decodeLyric + lrcTools；输出 原文/翻译/逐字）
//   pic           artistpicserver（rid → 500x500 封面直链）
//   url 兜底      www.kuwo.cn/api/v1/www/music/playUrl（Secret 签名，
//                 签名算法提取自酷我官网前端：Hm_Iuvt 种子 + token 逐字符混淆哈希）
//   歌单          酷我未公开免费歌单接口（GD音乐台亦未提供）→ 返回空，能力降级

enum AnyListenKw {
  // MARK: 搜索（r.s 明文接口；复刻 lx-music kw/musicSearch.js）

  static func musicSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    var c = URLComponents(string: "http://search.kuwo.cn/r.s")!
    c.queryItems = [
      .init(name: "client", value: "kt"),
      .init(name: "all", value: keyword),
      .init(name: "pn", value: "\(page - 1)"),
      .init(name: "rn", value: "\(limit)"),
      .init(name: "uid", value: "794762570"),
      .init(name: "ver", value: "kwplayer_ar_9.2.2.1"),
      .init(name: "vipver", value: "1"),
      .init(name: "show_copyright_off", value: "1"),
      .init(name: "newver", value: "1"),
      .init(name: "ft", value: "music"),
      .init(name: "cluster", value: "0"),
      .init(name: "strategy", value: "2012"),
      .init(name: "encoding", value: "utf8"),
      .init(name: "rformat", value: "json"),
      .init(name: "vermerge", value: "1"),
      .init(name: "mobi", value: "1"),
      .init(name: "issubtitle", value: "1"),
    ]
    let json = try await ALHttp.getJSON(c.url!.absoluteString,
      headers: ["Referer": "http://www.kuwo.cn/"]) as? [String: Any]
    let total = ALHttp.int(json?["TOTAL"]) ?? 0
    let abslist = json?["abslist"] as? [[String: Any]] ?? []
    let list = ALNormalize.dedup(abslist.compactMap(mapSearchItem)) { $0.songmid }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  /// r.s 条目 → MusicInfo（N_MINFO: level/bitrate/format/size → 音质档）
  private static func mapSearchItem(_ info: [String: Any]) -> MusicInfo? {
    guard let rid = info["MUSICRID"] as? String else { return nil }
    let songId = rid.replacingOccurrences(of: "MUSIC_", with: "")
    let nminfo = info["N_MINFO"] as? String ?? ""
    var quals: [MusicQualityType] = []
    if let rxp = try? NSRegularExpression(pattern: #"level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)"#) {
      let ns = nminfo as NSString
      for m in rxp.matches(in: nminfo, range: NSRange(location: 0, length: ns.length)) {
        let format = ns.substring(with: m.range(at: 3))
        let size = ns.substring(with: m.range(at: 4))
        switch format {
        case "4000": quals.append(.init(type: .flac24bit, size: size.uppercased()))
        case "2000": quals.append(.init(type: .flac, size: size.uppercased()))
        case "320": quals.append(.init(type: .q320k, size: size.uppercased()))
        case "128": quals.append(.init(type: .q128k, size: size.uppercased()))
        default: break
        }
      }
    }
    quals.reverse() // 高音质在前（对标 types.reverse()）
    let secs = ALHttp.int(info["DURATION"]) ?? 0
    return MusicInfo(
      name: iMusicSign.decode(ALHttp.str(info["SONGNAME"])),
      singer: iMusicSign.decode(ALHttp.str(info["ARTIST"])).replacingOccurrences(of: "&", with: "、"),
      source: .kw,
      songmid: songId,
      albumName: iMusicSign.decode(ALHttp.str(info["ALBUM"])),
      interval: iMusicSign.mmss(secs),
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: nil, // 封面按需走 artistpicserver（musicPic）
      extra: ["intervalSecs": "\(secs)"]
    )
  }

  // MARK: 榜单（kbangserver；bangid 参数化）

  static func topSongs() async -> [ALTopSongsItem] {
    // 主页目录收录的 bangid（Boards.swift 同源）；榜单名随接口返回，列表侧先给静态名
    [("16", "热歌榜"), ("93", "飙升榜"), ("17", "新歌榜"), ("158", "抖音热歌榜"), ("104", "华语榜"),
     ("182", "粤语榜"), ("22", "欧美榜"), ("183", "日语榜"), ("184", "韩语榜"), ("278", "古风音乐榜"),
     ("242", "电音榜"), ("176", "DJ嗨歌榜"), ("64", "影视金曲榜"), ("26", "经典怀旧榜")]
      .map { ALTopSongsItem(id: $0.0, name: $0.1, pic: nil) }
  }

  static func topSongsDetail(id: String, page: Int, limit: Int) async throws -> ALTopSongsDetailResult {
    let url = "http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&pn=\((page - 1) * limit)&rn=\(limit)&type=bang&data=content&id=\(id)&show_copyright_off=0&pcmp4=1&isbang=1"
    let json = try await ALHttp.getJSON(url) as? [String: Any]
    guard let list = json?["musiclist"] as? [[String: Any]] else {
      throw ALSourceError.invalidResponse("酷我榜单解析失败")
    }
    let info = ALTopSongsDetailInfo(
      name: ALHttp.str(json?["name"]),
      pic: json?["pic"] as? String,
      desc: ALHttp.str(json?["info"]),
      date: ALHttp.str(json?["pub"]))
    let musics = list.compactMap(mapBoardItem)
    let total = ALHttp.int(json?["num"]) ?? musics.count
    return ALTopSongsDetailResult(list: musics, total: max(total, musics.count), page: page, limit: limit, info: info)
  }

  /// kbangserver 条目（formats 串 → 音质档）
  private static func mapBoardItem(_ m: [String: Any]) -> MusicInfo? {
    guard let id = ALHttp.str(m["id"]) as String?, !id.isEmpty else { return nil }
    let formats = (m["formats"] as? String ?? "").components(separatedBy: "|")
    var quals: [MusicQualityType] = []
    if formats.contains("ALFLAC") { quals.append(.init(type: .flac, size: nil)) }
    if formats.contains("MP3H") { quals.append(.init(type: .q320k, size: nil)) }
    if formats.contains("MP3128") { quals.append(.init(type: .q128k, size: nil)) }
    if quals.isEmpty { quals = [.init(type: .q128k, size: nil)] }
    let secs = ALHttp.int(m["song_duration"] ?? m["duration"]) ?? 0
    return MusicInfo(
      name: iMusicSign.decode(ALHttp.str(m["name"])),
      singer: iMusicSign.decode(ALHttp.str(m["artist"])),
      source: .kw,
      songmid: id,
      albumName: iMusicSign.decode(ALHttp.str(m["album"])),
      interval: iMusicSign.mmss(secs),
      qualitys: quals,
      picUrl: m["web_albumpic_short"] as? String,
      extra: ["intervalSecs": "\(secs)"]
    )
  }

  // MARK: 歌单（酷我无公开免费歌单接口；GD音乐台同源亦无 → 降级为空）

  static func songlistTags() async -> ALSonglistTagResult { ALSonglistTagResult(tags: [], hotTags: []) }
  static func songlistSorts() async -> [ALTagItem] { [] }
  static func songlist(sort: String, tag: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    ALListResult(list: [], total: 0, page: page, limit: limit)
  }
  static func songlistSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    ALListResult(list: [], total: 0, page: page, limit: limit)
  }
  static func songlistDetail(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    ALSonglistDetailResult(list: [], total: 0, page: page, limit: limit,
      info: ALSongListDetailInfo(name: "", img: nil, desc: nil, author: nil, playCount: nil, date: nil))
  }

  // MARK: 歌词（mlyric mobi.s：lrcx 逐字解码，输出 原文/翻译/逐字）

  static func musicLyric(_ music: MusicInfo) async throws -> LyricInfo {
    let (data, resp) = try await ALHttp.getRaw(
      "http://mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=1&rid=\(music.songmid)&encode=utf8")
    guard resp.statusCode == 200,
          String(data: data.prefix(10), encoding: .utf8)?.lowercased() == "tp=content",
          let head = data.range(of: Data("\r\n\r\n".utf8)),
          let inflated = LyricCodec.zlibInflate(data.subdata(in: head.upperBound..<data.endIndex)),
          let b64 = Data(base64Encoded: inflated) else {
      throw ALSourceError.invalidResponse("酷我歌词获取失败")
    }
    // "yeelion" 循环 XOR（lx-music kw decodeLyric）
    let key = Array("yeelion".utf8)
    var out = [UInt8](repeating: 0, count: b64.count)
    let bytes = [UInt8](b64)
    for i in 0..<bytes.count { out[i] = bytes[i] ^ key[i % key.count] }
    guard let lrcxText = String(bytes: out, encoding: .utf8), !lrcxText.isEmpty else {
      throw ALSourceError.invalidResponse("酷我歌词解码失败")
    }
    guard let p = parseKwLrcx(lrcxText) else {
      throw ALSourceError.invalidResponse("酷我歌词为空")
    }
    return p
  }

  /// 复刻 lx-music kw/lyric.js parseLrc + lrcTools：
  /// 行内时间戳重复 → 第二条视为翻译（tlyric）；逐字标签 <a,b> → lxlyric（[kuwo:xxx] 缩放）
  private static func parseKwLrcx(_ text: String) -> LyricInfo? {
    let timeExp = try! NSRegularExpression(pattern: #"\[([\d:.]+)\]"#)
    var tags: [String] = []
    var items: [(time: String, text: String)] = []
    let wordTag = try! NSRegularExpression(pattern: #"<(-?\d+),(-?\d+)(?:,-?\d+)?>"#)
    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      let ns = trimmed as NSString
      let matches = timeExp.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
      if let last = matches.last {
        var time = ns.substring(with: last.range(at: 1))
        if time.range(of: #"\.\d\d$"#, options: .regularExpression) != nil {
          time += "0" // [mm:ss.xx] → [mm:ss.xx0]（lx 同款补零）
        }
        let textOut = timeExp.stringByReplacingMatches(in: trimmed, options: [], range: NSRange(location: 0, length: ns.length),
                                                      withTemplate: "").trimmingCharacters(in: .whitespaces)
        items.append((time, textOut))
      } else {
        tags.append(trimmed)
      }
    }
    guard !items.isEmpty else { return nil }
    // 重复时间戳 → 翻译行（lx sortLrcArr）
    var seen = Set<String>()
    var lrc: [(time: String, text: String)] = []
    var lrcT: [(time: String, text: String)] = []
    for item in items {
      if seen.contains(item.time) {
        if lrc.count >= 2 {
          var tItem = lrc.removeLast()
          tItem.time = lrc.last?.time ?? tItem.time
          lrcT.append(tItem)
          lrc.append(item)
        }
      } else {
        lrc.append(item)
        seen.insert(item.time)
      }
    }
    func plain(_ list: [(time: String, text: String)]) -> String {
      let body = list.map { "[\($0.time)]\($0.text)" }.joined(separator: "\n")
      return (tags.isEmpty ? body : (tags.joined(separator: "\n") + "\n" + body))
    }
    // 逐字标签剔除（展示用歌词不带 <a,b>)
    func stripWord(_ s: String) -> String {
      wordTag.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length),
                                       withTemplate: "")
    }
    let lyric = stripWord(plain(lrc))
    let tlyric = lrcT.isEmpty ? nil : stripWord(plain(lrcT))
    let lxlyric = buildLxLyric(plain(lrc), tags: tags)
    guard lyric.range(of: #"\[\d{1,2}:.*\d{1,4}\]"#, options: .regularExpression) != nil else { return nil }
    return LyricInfo(lyric: lyric, tlyric: tlyric, rlyric: nil, lxlyric: lxlyric)
  }

  /// 复刻 lx lrcTools.parse：kuwo lrcx 的 <a,b> 是（起+止, 起-止）编码，[kuwo:八进制] 给出缩放
  private static func buildLxLyric(_ plainLrc: String, tags: [String]) -> String? {
    var scale = 1, scale2 = 1
    for tag in tags {
      guard let m = tag.range(of: #"\[kuwo:(\d+)\]"#, options: .regularExpression) else { continue }
      let oct = String(tag[m.upperBound...]).prefix { $0.isNumber }
      if let v = Int(oct, radix: 8) { // [kuwo:xxx] 为八进制
        scale = v / 10
        scale2 = v % 10
        break
      }
    }
    guard scale > 0, scale2 > 0 else { return nil }
    let wordTag = try! NSRegularExpression(pattern: #"<(-?\d+),(-?\d+)(?:,-?\d+)?>"#)
    var lines: [String] = []
    var outTags: [String] = []
    for line in plainLrc.components(separatedBy: .newlines) {
      let ns = line as NSString
      guard wordTag.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else {
        if line.hasPrefix("[") { outTags.append(line) }
        continue
      }
      var result = ""
      var searchRange = NSRange(location: 0, length: ns.length)
      while let mm = wordTag.firstMatch(in: line, range: searchRange) {
        result += ns.substring(with: NSRange(location: searchRange.location, length: mm.range.location - searchRange.location))
        let av = Int(ns.substring(with: mm.range(at: 1))) ?? 0
        let bv = Int(ns.substring(with: mm.range(at: 2))) ?? 0
        let start = abs(av + bv) / (scale * 2)
        let end = abs(av - bv) / (scale2 * 2) + start
        result += "<\(start),\(max(0, end - start))>"
        searchRange.location = mm.range.location + mm.range.length
        searchRange.length = ns.length - searchRange.location
      }
      result += ns.substring(from: searchRange.location)
      lines.append(result)
    }
    guard !lines.isEmpty else { return nil }
    return (outTags.isEmpty ? "" : (outTags.joined(separator: "\n") + "\n")) + lines.joined(separator: "\n")
  }

  // MARK: 封面（artistpicserver：rid → 500 封面直链）

  static func musicPic(_ music: MusicInfo) async -> String? {
    let url = "http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=\(music.songmid)"
    guard let (data, _) = try? await ALHttp.getRaw(url),
          let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          s.hasPrefix("http") else { return nil }
    return s
  }

  // MARK: 播放直链兜底（www playUrl，Secret 签名；免费歌曲直出可播直链）

  static func musicUrl(_ music: MusicInfo, chain: [Int]) async -> ALMusicUrlInfo? {
    guard let token = await KwWeb.sessionToken(),
          let secret = KwWeb.secret(token: token) else { return nil }
    // www playUrl 只按 mid 直出当前可用流（免费歌曲 128k mp3；付费返回 code=-1 → 返回 nil 走换源）
    let url = "https://www.kuwo.cn/api/v1/www/music/playUrl?mid=\(music.songmid)&type=music&httpsStatus=1&reqId=\(KwWeb.reqId())&plat=web_www"
    guard let json = try? await ALHttp.getJSON(url, headers: [
      "Referer": "http://www.kuwo.cn/",
      "Cookie": "\(KwWeb.cookieName)=\(token)",
      "Secret": secret,
    ]) as? [String: Any],
          (json["code"] as? Int) == 200,
          let u = json["data"] as? String, u.hasPrefix("http") else { return nil }
    return ALMusicUrlInfo(url: u, quality: .q128k)
  }
}

// MARK: - 酷我 Web 会话（Secret 签名；算法提取自酷我官网前端 kw_dcc6cd7.js）

enum KwWeb {
  static let cookieName = "Hm_Iuvt_cdb524f42f23cer9b268564v7y735ewrq2324"

  private static let lock = NSLock()
  nonisolated(unsafe) private static var cachedTokenBox: String?  // NSLock 保护

  private static func cachedTokenGet() -> String? {
    lock.lock(); defer { lock.unlock() }
    return cachedTokenBox
  }

  private static func cachedTokenSet(_ v: String?) {
    lock.lock(); defer { lock.unlock() }
    cachedTokenBox = v
  }

  static func reqId() -> String {
    UUID().uuidString.lowercased()
  }

  /// 首页 Set-Cookie 下发的 token（服务端签发，缓存复用；拿不到时无 Secret 不可用）
  static func sessionToken() async -> String? {
    if let cached = cachedTokenGet(), !cached.isEmpty { return cached }
    guard let (data, resp) = try? await ALHttp.getRaw("https://www.kuwo.cn/",
      headers: ["Accept": "text/html,application/xhtml+xml"]),
          let fields = resp.value(forHTTPHeaderField: "Set-Cookie") ?? (resp.allHeaderFields["Set-Cookie"] as? String),
          let m = fields.range(of: "\(cookieName)=([^;]+)", options: .regularExpression) else { return nil }
    let token = String(fields[m.upperBound...]).prefix { $0 != ";" }
    guard !token.isEmpty else { return nil }
    cachedTokenSet(String(token))
    _ = data
    return cachedTokenGet()
  }

  /// 官网 f(t, e)：token 逐字符与种子派生的伪随机流 XOR → hex；末 8 位 hex 为随机盐 d
  static func secret(token: String) -> String? {
    let seed = cookieName
    var n = seed.unicodeScalars.map { String($0.value) }.joined()
    let o = n.count / 5
    func charAt(_ i: Int) -> String { i < n.count ? String(Array(n)[i]) : "" }
    guard let r = Int(charAt(o) + charAt(2 * o) + charAt(3 * o) + charAt(4 * o) + charAt(5 * o)), r >= 2 else { return nil }
    let c: Int64 = Int64(ceil(Double(seed.count) / 2))
    let l: Int64 = 2_147_483_647 // 2^31 - 1
    let r64: Int64 = Int64(r)
    let d = Int.random(in: 0..<100_000_000)
    n += String(d)
    // JS 折叠：n 长于 10 位则前 10 位与余段相加，直到 ≤10 位
    while n.count > 10 {
      let headPart = n.prefix(10)
      let restPart = n.dropFirst(10)
      let headVal = Int(headPart) ?? 0
      let restVal = Int(restPart) ?? 0
      n = String(headVal + restVal)
    }
    let nVal: Int64 = Int64(n) ?? 0
    var x: Int64 = (r64 * (nVal + c)) % l
    if x < 0 { x += l }
    var h = ""
    for ch in token.utf8 {
      let ratio = Double(x) / Double(l) * 255 // JS Math.floor(n/l*255)：浮点先除再取整
      let mask = Int(ratio.rounded(.down))
      let f = Int(ch) ^ mask
      let hex = String(f, radix: 16)
      h += f < 16 ? ("0" + hex) : hex
      x = (r64 * x + c) % l
      if x < 0 { x += l }
    }
    var dHex = String(d, radix: 16)
    while dHex.count < 8 { dHex = "0" + dHex }
    return h + dHex
  }
}
