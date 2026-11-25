import Foundation

// MARK: - 酷我解析（AnyListenKw）
//
// 按 any-listen 契约实现的酷我源资源动作；Swift 原生移植并对齐
// extensions/online-metadata/src/onlineResource/kw/*（端点已逐个实测）：
//   musicSearch   search.kuwo.cn/r.s（明文 JSON；N_MINFO 音质段逐档解析）
//   topSongs      kbangserver.kuwo.cn 榜单（bangid 参数化；主页目录的真正数据源）
//   lyric         mlyric.kuwo.cn/mobi.s（TP=content → zlib → base64 → "yeelion" XOR，
//                 对齐 extensions/online-metadata/src/onlineResource/kw/decodeLyric.ts + util.ts；输出 原文/翻译/逐字）
//   pic           artistpicserver（rid → 500x500 封面直链）
//   url 兜底      www.kuwo.cn/api/v1/www/music/playUrl（Secret 签名，
//                 签名算法提取自酷我官网前端：Hm_Iuvt 种子 + token 逐字符混淆哈希）
//   歌单          tags/sorts/list/search/detail 全链路原生移植自 .../kw/songlist*.ts
//                 （含 digest-8/5/13 与波点 BD 分支）；热搜/提示移植自 kw/hotSearch.ts、tipSearch.ts

enum AnyListenKw {
  // MARK: 搜索（r.s 明文接口；对齐 extensions/online-metadata/src/onlineResource/kw/musicSearch.ts）

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
    // 对齐 extensions/online-metadata/.../kw/musicSearch.ts：TOTAL 非 "0" 且 SHOW == "0" 视为失败
    if ALHttp.str(json?["SHOW"]) == "0", ALHttp.str(json?["TOTAL"]) != "0" {
      throw ALSourceError.invalidResponse("酷我搜索失败")
    }
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
    // 对齐 extensions/online-metadata/.../kw/musicSearch.ts：按 bitrate（第 2 组）分档，不倒序
    if let rxp = try? NSRegularExpression(pattern: #"level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)"#) {
      let ns = nminfo as NSString
      for m in rxp.matches(in: nminfo, range: NSRange(location: 0, length: ns.length)) {
        let bitrate = ns.substring(with: m.range(at: 2))
        let size = ns.substring(with: m.range(at: 4))
        switch bitrate {
        case "4000": quals.append(.init(type: .flac24bit, size: size.uppercased()))
        case "2000": quals.append(.init(type: .flac, size: size.uppercased()))
        case "320": quals.append(.init(type: .q320k, size: size.uppercased()))
        case "128": quals.append(.init(type: .q128k, size: size.uppercased()))
        default: break
        }
      }
    }
    let secs = ALHttp.int(info["DURATION"]) ?? 0
    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(info["SONGNAME"])),
      singer: ALFormat.decodeName(ALHttp.str(info["ARTIST"])).replacingOccurrences(of: "&", with: "、"),
      source: .kw,
      songmid: songId,
      albumName: ALFormat.decodeName(ALHttp.str(info["ALBUM"])),
      interval: ALFormat.playTime(secs),
      qualitys: quals,
      picUrl: nil, // 封面按需走 artistpicserver（musicPic）
      extra: ["intervalSecs": "\(secs)",
              "albumId": ALFormat.decodeName(ALHttp.str(info["ALBUMID"])),
              "songId": songId]
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
    let secs = ALHttp.int(m["song_duration"] ?? m["duration"]) ?? 0
    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(m["name"])),
      singer: ALFormat.decodeName(ALHttp.str(m["artist"])).replacingOccurrences(of: "&", with: "、"),
      source: .kw,
      songmid: id,
      albumName: ALFormat.decodeName(ALHttp.str(m["album"])),
      interval: ALFormat.playTime(secs),
      qualitys: quals,
      picUrl: m["pic"] as? String,
      extra: ["intervalSecs": "\(secs)"]
    )
  }

  // MARK: 歌单（原生移植 extensions/online-metadata/src/onlineResource/kw/songlist.ts 全链路）

  /// getTagList + getRcmTagList（两条 GET 均要求 HTTP 200 且 body.code == 200）
  static func songlistTags() async -> ALSonglistTagResult {
    let tagsURL = "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagList?cmd=rcm_keyword_playlist&user=0&prod=kwplayer_pc_9.0.5.0&vipver=9.0.5.0&source=kwplayer_pc_9.0.5.0&loginUid=0&loginSid=0&appUid=76039576"
    let hotURL = "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmTagList?loginUid=0&loginSid=0&appUid=76039576"
    let tagBody = (try? await ALHttp.getJSON(tagsURL, requireOK: true)) as? [String: Any]
    let hotBody = (try? await ALHttp.getJSON(hotURL, requireOK: true)) as? [String: Any]

    var groups: [ALTagGroupItem] = []
    if let body = tagBody, ALHttp.int(body["code"]) == 200 {
      for type in ALHttp.arr(body["data"]) ?? [] {
        let items: [ALTagItem] = ALHttp.arr(type["data"])?.compactMap { item in
          kwTagItem(item)
        } ?? []
        groups.append(ALTagGroupItem(name: ALHttp.str(type["name"]), list: items))
      }
    }
    var hotTags: [ALTagItem] = []
    if let body = hotBody, ALHttp.int(body["code"]) == 200,
       let first = ALHttp.arr(body["data"])?.first {
      hotTags = ALHttp.arr(first["data"])?.compactMap { kwTagItem($0) } ?? []
    }
    return ALSonglistTagResult(tags: groups, hotTags: hotTags)
  }

  static func songlistSorts() async -> [ALTagItem] {
    // 扩展返回 i18n 占位符 `{songlist.sort.new|hot}`；iMusic 直接用展示名
    [ALTagItem(id: "new", name: "最新"), ALTagItem(id: "hot", name: "最热")]
  }

  /// 标签浏览：无标签走 wapi getRcmPlayList（固定 rn=36），有标签走 mobileinterfaces er.s
  /// （er.s 无数据时按扩展 getListUrl 回退 getTagPlayList）
  static func songlist(sort: String, tag: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    if tag.isEmpty {
      let url = "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?loginUid=0&loginSid=0&appUid=76039576&&pn=\(page)&rn=36&order=\(sort)"
      let json = try await ALHttp.getJSON(url, requireOK: true) as? [String: Any]
      let data = ALHttp.dict(json?["data"]) ?? [:]
      let raw = ALHttp.arr(data["data"]) ?? []
      let list = ALNormalize.dedup(raw.compactMap(mapKwSonglistItem)) { $0.id }
      return ALListResult(list: list,
                          total: ALHttp.int(data["total"]) ?? list.count,
                          page: ALHttp.int(data["pn"]) ?? page,
                          limit: ALHttp.int(data["rn"]) ?? 36)
    }
    // tag id 形如 `<id>-<digest>`；扩展取 `-` 前一段作为 er.s 的 id
    let parts = tag.split(separator: "-", maxSplits: 1)
    let id = parts.first.map(String.init) ?? tag
    let url = "http://mobileinterfaces.kuwo.cn/er.s?type=get_pc_qz_data&f=web&id=\(id)&prod=pc"
    let groups = (try await ALHttp.getJSON(url, requireOK: true)) as? [[String: Any]] ?? []
    var list: [ALSongListItem] = []
    for group in groups {
      for item in ALHttp.arr(group["list"]) ?? [] {
        // 对齐 filterList2：digest 5=list / 8=songlist / 13=album，其余（如 4=artist）丢弃
        guard ["songlist", "list", "album"].contains(ALHttp.str(item["type"])) else { continue }
        list.append(ALSongListItem(
          id: "digest-\(ALHttp.str(item["digest"]))__\(ALHttp.str(item["id"]))",
          name: ALFormat.decodeName(ALHttp.str(item["name"])),
          time: kwFormatYMD(item["publish"] ?? item["ctime"]),
          img: item["img"] as? String,
          desc: ALFormat.decodeName(ALHttp.str(item["desc"])),
          total: ALHttp.int(item["total"] ?? item["songnum"])))
      }
    }
    list = ALNormalize.dedup(list) { $0.id }
    if list.isEmpty {
      // er.s 只覆盖「专区」类标签；digest=10000 的常规标签按扩展 getListUrl 走 getTagPlayList
      let tagURL = "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList?loginUid=0&loginSid=0&appUid=76039576&pn=\(page)&id=\(id)&rn=36"
      if let json = (try? await ALHttp.getJSON(tagURL, requireOK: true)) as? [String: Any] {
        let data = ALHttp.dict(json["data"]) ?? [:]
        let fallback = ALNormalize.dedup((ALHttp.arr(data["data"]) ?? []).compactMap(mapKwSonglistItem)) { $0.id }
        if !fallback.isEmpty {
          return ALListResult(list: fallback,
                              total: ALHttp.int(data["total"]) ?? fallback.count,
                              page: ALHttp.int(data["pn"]) ?? page,
                              limit: ALHttp.int(data["rn"]) ?? 36)
        }
      }
    }
    return ALListResult(list: list, total: list.count, page: page, limit: limit)
  }

  /// r.s 返回单引号 JS 对象字面量（objStr2JSON 转换后解析）
  static func songlistSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    let url = "http://search.kuwo.cn/r.s?all=\(kwQueryEncode(keyword))&pn=\(page - 1)&rn=\(limit)&rformat=json&encoding=utf8&ver=mbox&vipver=MUSIC_8.7.7.0_BCS37&plat=pc&devid=28156413&ft=playlist&pay=0&needliveshow=0"
    let (data, resp) = try await ALHttp.getRaw(url, requireOK: true)
    guard resp.statusCode == 200,
          let text = String(data: data, encoding: .utf8),
          let body = kwObjStr2JSON(text) else {
      throw ALSourceError.invalidResponse("酷我歌单搜索解析失败")
    }
    let raw = ALHttp.arr(body["abslist"]) ?? []
    let list = ALNormalize.dedup(raw.compactMap { item -> ALSongListItem? in
      let id = ALHttp.str(item["playlistid"])
      guard !id.isEmpty else { return nil }
      return ALSongListItem(
        id: id,
        name: ALFormat.decodeName(ALHttp.str(item["name"])),
        playCount: ALFormat.playCount(item["playcnt"]),
        author: ALFormat.decodeName(ALHttp.str(item["nickname"])),
        time: kwFormatYMD(item["publish"]),
        img: item["pic"] as? String,
        desc: ALFormat.decodeName(ALHttp.str(item["intro"])),
        total: ALHttp.int(item["songnum"]))
    }) { $0.id }
    return ALListResult(list: list, total: ALHttp.int(body["TOTAL"]) ?? list.count, page: page, limit: limit)
  }

  /// 路由对齐 getListDetail：/bodian/ → BD，URL/带 `?&:/` → 提取 playlist id，
  /// digest-8 → pl.svc，digest-13 → 专辑，digest-5/默认 → qukudata 解析后 pl.svc
  static func songlistDetail(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    if id.contains("/bodian/") {
      return try await songlistDetailBD(id, page: page, limit: limit)
    }
    if id.range(of: #"[?&:/]"#, options: .regularExpression) != nil {
      let rawId = kwPlaylistIdFromLink(id) ?? id
      return try await songlistDetailDigest8(rawId, page: page, limit: limit)
    }
    if id.hasPrefix("digest-") {
      let parts = id.split(separator: "__", maxSplits: 1)
      let digest = parts.first.map(String.init) ?? ""
      let rawId = parts.count > 1 ? String(parts[1]) : ""
      switch digest.replacingOccurrences(of: "digest-", with: "") {
      case "13": return try await songlistDetailAlbum(rawId, page: page, limit: limit)
      case "8": return try await songlistDetailDigest8(rawId, page: page, limit: limit)
      default: return try await songlistDetailDigest5(rawId, page: page, limit: limit)
      }
    }
    return try await songlistDetailDigest8(id, page: page, limit: limit)
  }

  // MARK: 热搜 / 搜索提示（kw/hotSearch.ts、kw/tipSearch.ts）

  static func hotSearch() async throws -> [String] {
    let url = "http://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo&newver=2&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1&notrace=0&uid=0&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1"
    let json = (try await ALHttp.getJSON(url, headers: ["User-Agent": "Dalvik/2.1.0 (Linux; U; Android 9;)"],
      requireOK: true)) as? [String: Any]
    guard ALHttp.str(json?["status"]) == "ok" else {
      throw ALSourceError.invalidResponse("酷我热搜失败")
    }
    return (ALHttp.arr(json?["tagvalue"]) ?? []).compactMap { item in
      let key = ALHttp.str(item["key"])
      return key.isEmpty ? nil : key
    }
  }

  static func tipSearch(keyword: String) async throws -> [String] {
    let url = "https://tips.kuwo.cn/t.s?corp=kuwo&newver=3&p2p=1&notrace=0&c=mbox&w=\(kwQueryEncode(keyword))&encoding=utf8&rformat=json"
    let json = (try await ALHttp.getJSON(url, headers: ["Referer": "http://www.kuwo.cn/"],
      requireOK: true)) as? [String: Any]
    guard let items = ALHttp.arr(json?["WORDITEMS"]) else {
      throw ALSourceError.invalidResponse("酷我搜索提示失败")
    }
    return items.compactMap { item in
      let word = ALHttp.str(item["RELWORD"])
      return word.isEmpty ? nil : word
    }
  }

  // MARK: 歌单链路私有工具

  /// 仿 Mg.queryEncode：`.urlQueryAllowed` 会保留 `&`/`=`/`?`，关键词必须按 RFC3986 严格编码
  private static func kwQueryEncode(_ text: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }

  /// shared/common.ts dateFormat(value, 'Y-M-D')；兼容 yyyy-MM-dd 文本与秒级时间戳
  private static func kwFormatYMD(_ value: Any?) -> String? {
    let raw = ALHttp.str(value).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    let out = DateFormatter()
    out.locale = Locale(identifier: "en_US_POSIX")
    out.dateFormat = "yyyy-MM-dd"
    if raw.range(of: #"^\d{9,13}$"#, options: .regularExpression) != nil,
       let ts = Double(raw) {
      return out.string(from: Date(timeIntervalSince1970: ts))
    }
    let trimmed = raw.contains("T") ? raw : String(raw.split(separator: ".").first ?? Substring(raw))
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yyyy/MM/dd"] {
      parser.dateFormat = fmt
      if let d = parser.date(from: trimmed) { return out.string(from: d) }
    }
    let prefix = String(trimmed.prefix(10))
    return prefix.count == 10 ? prefix : nil
  }

  /// kw/util.ts objStr2JSON：单引号 JS 对象字面量 → JSON；只转换结构位置的引号，
  /// 字符串内部撇号（如 I'm）保留，避免误闭合。
  private static func kwObjStr2JSON(_ text: String) -> [String: Any]? {
    let chars = Array(text)
    func prevNonSpace(_ idx: Int) -> Character? {
      var i = idx - 1
      while i >= 0 {
        let c = chars[i]
        if c == " " || c == "\n" || c == "\r" || c == "\t" { i -= 1; continue }
        return c
      }
      return nil
    }
    func nextNonSpace(_ idx: Int) -> Character? {
      var i = idx + 1
      while i < chars.count {
        let c = chars[i]
        if c == " " || c == "\n" || c == "\r" || c == "\t" { i += 1; continue }
        return c
      }
      return nil
    }
    var out = ""
    var quote: Character? = nil
    var escaped = false
    for i in chars.indices {
      let ch = chars[i]
      if escaped {
        out.append(ch)
        escaped = false
        continue
      }
      if ch == "\\", quote != nil {
        out.append(ch)
        escaped = true
        continue
      }
      if let q = quote {
        if ch == q {
          if q == "'" {
            if let n = nextNonSpace(i), [":", ",", "}", "]"].contains(n) || i == chars.count - 1 {
              out.append("\"")
              quote = nil
            } else {
              out.append("'") // 字符串中的撇号
            }
          } else {
            out.append("\"")
            quote = nil
          }
        } else if q == "'", ch == "\"" {
          out.append("\\\"") // 单引号串里的双引号需转义后才能交给 JSONSerialization
        } else {
          out.append(ch)
        }
        continue
      }
      if ch == "'" || ch == "\"" {
        // 开引号：对象/数组起始、逗号或冒号之后
        if let p = prevNonSpace(i), ["{", "[", ",", ":"].contains(p) {
          quote = ch
          out.append("\"")
        } else if prevNonSpace(i) == nil {
          quote = ch
          out.append("\"")
        } else {
          out.append(ch)
        }
        continue
      }
      out.append(ch)
    }
    guard let data = out.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return obj
  }

  private static func kwTagItem(_ item: [String: Any]) -> ALTagItem? {
    let id = ALHttp.str(item["id"])
    guard !id.isEmpty else { return nil }
    return ALTagItem(id: "\(id)-\(ALHttp.str(item["digest"]))", name: ALHttp.str(item["name"]))
  }

  private static func mapKwSonglistItem(_ item: [String: Any]) -> ALSongListItem? {
    let id = ALHttp.str(item["id"])
    guard !id.isEmpty else { return nil }
    return ALSongListItem(
      id: "digest-\(ALHttp.str(item["digest"]))__\(id)",
      name: ALFormat.decodeName(ALHttp.str(item["name"])),
      playCount: ALFormat.playCount(item["listencnt"] ?? item["playcnt"]),
      author: ALFormat.decodeName(ALHttp.str(item["uname"] ?? item["nickname"])),
      time: kwFormatYMD(item["publish"] ?? item["ctime"] ?? item["time"]),
      img: item["img"] as? String,
      desc: ALFormat.decodeName(ALHttp.str(item["desc"] ?? item["info"])),
      total: ALHttp.int(item["total"] ?? item["songnum"]))
  }

  /// N_MINFO 多段（level/bitrate/format/size）→ 音质档；与 ALQualityBridge 档位一一对应
  private static func kwQualitys(fromNMinInfo nminfo: String) -> [MusicQualityType] {
    guard let re = try? NSRegularExpression(pattern: #"level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)"#) else {
      return []
    }
    let ns = nminfo as NSString
    var quals: [MusicQualityType] = []
    for m in re.matches(in: nminfo, range: NSRange(location: 0, length: ns.length)) {
      let bitrate = ALHttp.int(ns.substring(with: m.range(at: 2))) ?? 0
      guard [128, 320, 2000, 4000].contains(bitrate) else { continue }
      let size = ns.substring(with: m.range(at: 4)).uppercased()
      quals.append(.init(type: ALQualityBridge.fromBr(bitrate), size: size))
    }
    return quals
  }

  /// pl.svc musiclist 条目（对齐 filterListDetail）
  private static func mapKwDetailItem(_ m: [String: Any]) -> MusicInfo? {
    let id = ALHttp.str(m["id"])
    guard !id.isEmpty else { return nil }
    let secs = ALHttp.int(m["duration"]) ?? 0
    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(m["name"])),
      singer: ALFormat.decodeName(ALHttp.str(m["artist"])).replacingOccurrences(of: "&", with: "、"),
      source: .kw,
      songmid: id,
      albumName: ALFormat.decodeName(ALHttp.str(m["album"])),
      interval: ALFormat.playTime(secs),
      qualitys: kwQualitys(fromNMinInfo: ALHttp.str(m["N_MINFO"])),
      picUrl: (m["albumpic"] as? String) ?? (m["musicPic"] as? String),
      extra: ["intervalSecs": "\(secs)", "albumId": ALHttp.str(m["albumid"]), "songId": id])
  }

  /// pl.svc 响应 → ALSonglistDetailResult（digest-8 / digest-5 共用）
  private static func kwMapDetailResponse(_ json: [String: Any]?, page: Int, limit: Int) -> ALSonglistDetailResult? {
    guard let json, ALHttp.str(json["result"]) == "ok" else { return nil }
    let list = ALNormalize.dedup((ALHttp.arr(json["musiclist"]) ?? []).compactMap(mapKwDetailItem)) { $0.songmid }
    let info = ALSongListDetailInfo(
      name: ALHttp.str(json["title"]),
      img: json["pic"] as? String,
      desc: json["info"] as? String,
      author: json["uname"] as? String,
      playCount: ALFormat.playCount(json["playnum"]),
      date: kwFormatYMD(json["ctime"] ?? json["pub"]))
    return ALSonglistDetailResult(list: list,
                                  total: ALHttp.int(json["total"]) ?? list.count,
                                  page: page,
                                  limit: ALHttp.int(json["rn"]) ?? limit,
                                  info: info)
  }

  /// digest-8：nplserver pl.svc（vipver/newver 参数）
  private static func songlistDetailDigest8(_ id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    let url = "http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=\(id)&pn=\(page - 1)&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1"
    let json = (try await ALHttp.getJSON(url, requireOK: true)) as? [String: Any]
    guard let result = kwMapDetailResponse(json, page: page, limit: limit) else {
      throw ALSourceError.invalidResponse("酷我歌单详情失败")
    }
    return result
  }

  /// digest-5：先 qukudata 解析真实 sourceid，再走 pl.svc（encode=utf-8）
  private static func songlistDetailDigest5(_ id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    let infoURL = "http://qukudata.kuwo.cn/q.k?op=query&cont=ninfo&node=\(id)&pn=0&rn=1&fmt=json&src=mbox&level=2"
    let infoJSON = (try? await ALHttp.getJSON(infoURL, requireOK: true)) as? [String: Any]
    let children = ALHttp.arr(infoJSON?["child"]) ?? []
    guard let first = children.first, !ALHttp.str(first["sourceid"]).isEmpty else {
      throw ALSourceError.invalidResponse("酷我歌单解析失败")
    }
    let detailId = ALHttp.str(first["sourceid"])
    let url = "http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=\(detailId)&pn=\(page - 1)&rn=1000&encode=utf-8&keyset=pl2012&identity=kuwo&pcmp4=1"
    let json = (try await ALHttp.getJSON(url, requireOK: true)) as? [String: Any]
    guard let result = kwMapDetailResponse(json, page: page, limit: limit) else {
      throw ALSourceError.invalidResponse("酷我歌单详情失败")
    }
    return result
  }

  /// digest-13：search.kuwo.cn stype=albuminfo（单引号对象字面量 → objStr2JSON）
  private static func songlistDetailAlbum(_ id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    let url = "http://search.kuwo.cn/r.s?pn=\(page - 1)&rn=\(limit)&stype=albuminfo&albumid=\(id)&show_copyright_off=0&encoding=utf&vipver=MUSIC_9.1.0"
    let (data, resp) = try await ALHttp.getRaw(url, requireOK: true)
    guard resp.statusCode == 200,
          let text = String(data: data, encoding: .utf8),
          let body = kwObjStr2JSON(text),
          let raw = ALHttp.arr(body["musiclist"]) else {
      throw ALSourceError.invalidResponse("酷我专辑解析失败")
    }
    let albumName = ALFormat.decodeName(ALHttp.str(body["name"]))
    let albumId = ALHttp.str(body["albumid"])
    let list = ALNormalize.dedup(raw.compactMap { item -> MusicInfo? in
      let sid = ALHttp.str(item["id"])
      guard !sid.isEmpty else { return nil }
      let formats = ALHttp.str(item["formats"]).components(separatedBy: "|")
      var qs: [MusicQualityType] = []
      if formats.contains("MP3128") { qs.append(.init(type: .q128k, size: nil)) }
      if formats.contains("MP3H") { qs.append(.init(type: .q320k, size: nil)) }
      if formats.contains("ALFLAC") { qs.append(.init(type: .flac, size: nil)) }
      if formats.contains("HIRFLAC") { qs.append(.init(type: .flac24bit, size: nil)) }
      let secs = Int(ALHttp.str(item["duration"]))
      return MusicInfo(
        name: ALFormat.decodeName(ALHttp.str(item["name"])),
        singer: ALFormat.decodeName(ALHttp.str(item["artist"])).replacingOccurrences(of: "&", with: "、"),
        source: .kw,
        songmid: sid,
        albumName: albumName,
        interval: secs.map { ALFormat.playTime($0) },
        qualitys: qs,
        picUrl: (item["img"] as? String) ?? (item["pic120"] as? String),
        extra: ["albumId": albumId, "songId": sid, "intervalSecs": "\(secs ?? 0)"])
    }) { $0.songmid }
    let info = ALSongListDetailInfo(
      name: albumName,
      img: (body["img"] as? String) ?? (body["hts_img"] as? String),
      desc: ALFormat.decodeName(ALHttp.str(body["info"])),
      author: ALFormat.decodeName(ALHttp.str(body["artist"])),
      playCount: nil,
      date: kwFormatYMD(body["pub"]))
    return ALSonglistDetailResult(list: list,
                                  total: ALHttp.int(body["songnum"]) ?? list.count,
                                  page: page, limit: limit, info: info)
  }

  /// 波点歌单（bd-api；对应 kw/songlistBD.ts 全链路）
  private static var kwBDHeaders: [String: String] {
    ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36",
     "plat": "h5"]
  }

  /// 8 段 4 位十六进制（对齐 getReqId：65536*(1+random) 取低 16 位）
  private static func kwReqId() -> String {
    (0..<8).map { _ in
      let v = Int.random(in: 0x10000...0x1FFFF)
      return String(String(v, radix: 16).dropFirst())
    }.joined()
  }

  private static func mapKwBDItem(_ item: [String: Any]) -> MusicInfo? {
    let id = ALHttp.str(item["id"])
    guard !id.isEmpty else { return nil }
    var quals: [MusicQualityType] = []
    for audio in ALHttp.arr(item["audios"]) ?? [] {
      let bitrate = ALHttp.int(audio["bitrate"]) ?? 0
      guard [128, 320, 2000, 4000].contains(bitrate) else { continue }
      quals.append(.init(type: ALQualityBridge.fromBr(bitrate),
                         size: (audio["size"] as? String)?.uppercased()))
    }
    return MusicInfo(
      name: ALHttp.str(item["name"]),
      singer: ALFormat.singerName(item["artists"]),
      source: .kw,
      songmid: id,
      albumName: ALHttp.str(item["album"]),
      interval: ALFormat.playTime(ALHttp.int(item["duration"]) ?? 0),
      qualitys: quals,
      picUrl: item["albumPic"] as? String,
      extra: ["albumId": ALHttp.str(item["albumId"]), "songId": id])
  }

  private static func songlistDetailBD(_ id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    func capture(_ pattern: String) -> String? {
      guard let re = try? NSRegularExpression(pattern: pattern),
            let m = re.firstMatch(in: id, range: NSRange(location: 0, length: (id as NSString).length)),
            let r = Range(m.range(at: 1), in: id) else { return nil }
      return String(id[r])
    }
    guard let listId = capture(#"playlistId=(\d+)"#) else {
      throw ALSourceError.invalidResponse("酷我波点歌单解析失败")
    }
    let uid = capture(#"uid=(\d+)"#)
    let source = capture(#"source=(\d+)"#) ?? "4"
    let reqId = kwReqId()
    let listURL = "https://bd-api.kuwo.cn/api/service/playlist/\(listId)/musicList?reqId=\(reqId)&source=\(source)&pn=\(page)&rn=1000"
    let json = (try await ALHttp.getJSON(listURL, headers: kwBDHeaders, requireOK: true)) as? [String: Any]
    guard ALHttp.int(json?["code"]) == 200, let data = ALHttp.dict(json?["data"]) else {
      throw ALSourceError.invalidResponse("酷我波点歌单解析失败")
    }
    let list = ALNormalize.dedup((ALHttp.arr(data["list"]) ?? []).compactMap(mapKwBDItem)) { $0.songmid }
    var info = ALSongListDetailInfo(name: "", img: "", desc: "", author: "", playCount: "", date: nil)
    if source == "4" {
      let url = "https://bd-api.kuwo.cn/api/service/playlist/info/\(listId)?reqId=\(reqId)&source=\(source)"
      if let j = (try? await ALHttp.getJSON(url, headers: kwBDHeaders, requireOK: true)) as? [String: Any],
         ALHttp.int(j["code"]) == 200,
         let d = ALHttp.dict(j["data"]) {
        info = ALSongListDetailInfo(
          name: "\(ALHttp.str(d["name"]))喜欢的音乐",
          img: d["pic"] as? String,
          desc: d["description"] as? String,
          author: d["creatorName"] as? String,
          playCount: ALFormat.playCount(d["playNum"]),
          date: kwFormatYMD(d["lastPlayTime"]))
      }
    } else if source == "5" {
      let url = "https://bd-api.kuwo.cn/api/ucenter/users/pub/\(uid ?? listId)?reqId=\(reqId)"
      if let j = (try? await ALHttp.getJSON(url, headers: kwBDHeaders, requireOK: true)) as? [String: Any],
         ALHttp.int(j["code"]) == 200,
         let d = ALHttp.dict(j["data"]),
         let u = ALHttp.dict(d["userInfo"]) {
        let nickname = ALHttp.str(u["nickname"])
        info = ALSongListDetailInfo(name: "\(nickname)喜欢的音乐",
                                    img: u["headImg"] as? String,
                                    desc: "", author: nickname, playCount: "", date: nil)
      }
    }
    return ALSonglistDetailResult(list: list,
                                  total: ALHttp.int(data["total"]) ?? list.count,
                                  page: page,
                                  limit: ALHttp.int(data["pageSize"]) ?? limit,
                                  info: info)
  }

  /// /playlist/123 或 /playlist_detail/123?... → 123（对齐 regExps.listDetailLink）
  private static func kwPlaylistIdFromLink(_ id: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: #"/playlist(?:_detail)?/(\d+)"#),
          let m = re.firstMatch(in: id, range: NSRange(location: 0, length: (id as NSString).length)),
          let r = Range(m.range(at: 1), in: id) else { return nil }
    return String(id[r])
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
    // "yeelion" 循环 XOR（对齐 extensions/online-metadata/src/onlineResource/kw/decodeLyric.ts）
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

  /// 对齐 extensions/online-metadata/src/onlineResource/kw/lyric.ts parseLrc + util.ts lrcTools：
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
          time += "0" // [mm:ss.xx] → [mm:ss.xx0]（对齐 kw/lyric.ts 补零）
        }
        let textOut = timeExp.stringByReplacingMatches(in: trimmed, options: [], range: NSRange(location: 0, length: ns.length),
                                                      withTemplate: "").trimmingCharacters(in: .whitespaces)
        items.append((time, textOut))
      } else {
        tags.append(trimmed)
      }
    }
    guard !items.isEmpty else { return nil }
    // 重复时间戳 → 翻译行（对齐 kw/lyric.ts sortLrcArr）
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

  /// 对齐 extensions/online-metadata/src/onlineResource/kw/util.ts lrcTools.parse：kuwo lrcx 的 <a,b> 是（起+止, 起-止）编码，[kuwo:八进制] 给出缩放
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
    // 对齐 extensions/online-metadata/.../kw/pic.ts：kwcdn 域名改回 kuwo.cn，并升 http→https
    var result = s
    if result.hasPrefix("http://"), result.contains(".kwcdn.kuwo.cn") {
      result = result.replacingOccurrences(of: ".kwcdn.kuwo.cn", with: ".kuwo.cn")
      result = result.replacingOccurrences(of: "http://", with: "https://")
    }
    return result
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
