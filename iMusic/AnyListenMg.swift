import Foundation

// MARK: - 咪咕解析（AnyListenMg）
//
// 按 any-listen 契约实现的咪咕源资源动作（端点已逐个实测）：
//   musicSearch   jadeite.migu.cn/music_search/v3/search/searchAll（md5 签名，
//                 audioFormats 四档音质段；img1/2/3 封面）
//   topSongs      app.c.nf.migu.cn querycontentbyId（尖叫热歌榜 columnId 参数化）
//   lyric         搜索/榜单条目自带 lrcUrl（d.musicapp.migu.cn 明文 LRC 直链）
//   pic           条目自带 img1/2/3（相对路径补 d.musicapp.migu.cn 前缀）
//   歌单           咪咕歌单公开端点已全部下线（同 GD音乐台亦无）→ 返回空，能力降级
//   url           无公开直链（对标 any-listen：mg 直链由 LX 自定义源脚本提供）

enum AnyListenMg {
  private static let deviceId = "963B7AA0D21511ED807EE5846EC87D20"

  // MARK: 搜索（jadeite 签名搜索）

  static func musicSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    let time = "\(Int(Date().timeIntervalSince1970 * 1000))"
    let sig = iMusicSign.mgSign(time: time, keyword: keyword)
    let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
    let url = "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch=%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D&pageSize=\(limit)&text=\(q)&pageNo=\(page)&sort=0&sid=USS"
    let json = try await ALHttp.getJSON(url, headers: [
      "uiVersion": "A_music_3.6.1", "deviceId": sig.deviceId, "timestamp": time, "sign": sig.sign,
      "channel": "0146921",
      "User-Agent": "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn) AppleWebKit/534.30 Version/4.0 Mobile Safari/534.30",
    ]) as? [String: Any]
    guard (json?["code"] as? String) == "000000",
          let sr = json?["songResultData"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("咪咕搜索失败：\(json?["info"] ?? "")")
    }
    var out: [MusicInfo] = []
    var seen = Set<String>()
    for group in sr["resultList"] as? [[[String: Any]]] ?? [] {
      for d in group {
        guard let sid = d["songId"] as? String, let cid = d["copyrightId"] as? String,
              seen.insert(cid).inserted else { continue }
        out.append(mapSearchItem(d, songId: sid, copyrightId: cid))
      }
    }
    let total = ALHttp.int(sr["totalCount"]) ?? out.count
    return ALListResult(list: out, total: total, page: page, limit: limit)
  }

  /// jadeite 搜索条目 → MusicInfo（img1/2/3 + audioFormats 音质 + lrcUrl）
  static func mapSearchItem(_ d: [String: Any], songId: String, copyrightId: String) -> MusicInfo {
    var quals: [MusicQualityType] = []
    for t in (d["audioFormats"] as? [[String: Any]] ?? []) {
      let size = iMusicSign.size(t["asize"] ?? t["isize"])
      switch t["formatType"] as? String {
      case "PQ": quals.append(.init(type: .q128k, size: size))
      case "HQ": quals.append(.init(type: .q320k, size: size))
      case "SQ": quals.append(.init(type: .flac, size: size))
      case "ZQ24": quals.append(.init(type: .flac24bit, size: size))
      default: break
      }
    }
    var img = ALHttp.str(d["img3"]).isEmpty ? ALHttp.str(d["img2"]) : ALHttp.str(d["img3"])
    if img.isEmpty { img = ALHttp.str(d["img1"]) }
    if !img.isEmpty && !img.hasPrefix("http") { img = "http://d.musicapp.migu.cn" + img }
    let singers: String = {
      if let arr = d["singerList"] as? [[String: Any]] { return iMusicSign.singerNames(arr) }
      if let arr = d["singerList"] as? [String] { return arr.joined(separator: "、") }
      return ALHttp.str(d["singer"])
    }()
    let secs = ALHttp.int(d["duration"]) ?? 0
    let lrcUrl = ALHttp.str(d["lrcUrl"])
    return MusicInfo(
      name: ALHttp.str(d["name"]), singer: singers,
      source: .mg, songmid: songId,
      albumName: ALHttp.str(d["album"]),
      interval: iMusicSign.mmss(secs),
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: img.isEmpty ? nil : img,
      extra: ["copyrightId": copyrightId, "albumId": ALHttp.str(d["albumId"]),
              "lrcUrl": lrcUrl, "trcUrl": ALHttp.str(d["trcUrl"]), "intervalSecs": "\(secs)"]
    )
  }

  // MARK: 榜单（querycontentbyId；columnId 参数化）

  static func topSongs() async -> [ALTopSongsItem] {
    [ALTopSongsItem(id: "27186466", name: "尖叫热歌榜", pic: nil)]
  }

  static func topSongsDetail(id: String, page: Int, limit: Int) async throws -> ALTopSongsDetailResult {
    let json = try await ALHttp.getJSON(
      "https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do?columnId=\(id)&needAll=0",
      headers: ["Referer": "https://app.c.nf.migu.cn/",
                "User-Agent": "Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36",
                "channel": "0146921"]) as? [String: Any]
    guard (json?["code"] as? String) == "000000",
          let columnInfo = json?["columnInfo"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("咪咕榜单失败")
    }
    let contents = columnInfo["contents"] as? [[String: Any]] ?? []
    var out: [MusicInfo] = []
    var seen = Set<String>()
    for c in contents {
      guard let o = c["objectInfo"] as? [String: Any],
            let sid = o["songId"] as? String,
            seen.insert(sid).inserted else { continue }
      guard let m = mapBoardSong(o, songId: sid) else { continue }
      out.append(m)
      if limit > 0, out.count >= limit { break }
    }
    let info = ALTopSongsDetailInfo(
      name: ALHttp.str(columnInfo["columnTitle"]),
      pic: nil, desc: nil, date: ALHttp.str(columnInfo["columnUpdateTime"]))
    return ALTopSongsDetailResult(list: out, total: out.count, page: page, limit: limit, info: info)
  }

  /// querycontentbyId 条目（newRateFormats 音质 + albumImgs 封面 + lrcUrl）
  private static func mapBoardSong(_ o: [String: Any], songId: String) -> MusicInfo? {
    guard let cid = o["copyrightId"] as? String else { return nil }
    var quals: [MusicQualityType] = []
    for t in (o["newRateFormats"] as? [[String: Any]] ?? []) {
      let size = iMusicSign.size(t["size"] ?? t["androidSize"])
      switch t["formatType"] as? String {
      case "PQ": quals.append(.init(type: .q128k, size: size))
      case "HQ": quals.append(.init(type: .q320k, size: size))
      case "SQ": quals.append(.init(type: .flac, size: size))
      case "ZQ": quals.append(.init(type: .flac24bit, size: size))
      default: break
      }
    }
    let singers = (o["artists"] as? [[String: Any]]).map(iMusicSign.singerNames) ?? ALHttp.str(o["singer"])
    var img = ((o["albumImgs"] as? [[String: Any]])?.first?["img"] as? String) ?? ""
    if !img.isEmpty && !img.hasPrefix("http") { img = "http://d.musicapp.migu.cn" + img }
    // length 形如 "03:45"（对标 filterMusicInfoList 取尾部）
    let length = ALHttp.str(o["length"])
    var interval: String? = nil
    if let r = try? NSRegularExpression(pattern: #"(\d\d:\d\d)$"#),
       let m = r.firstMatch(in: length, range: NSRange(location: 0, length: (length as NSString).length)) {
      interval = (length as NSString).substring(with: m.range(at: 1))
    }
    let lrcUrl = ALHttp.str(o["lrcUrl"])
    return MusicInfo(
      name: ALHttp.str(o["songName"]), singer: singers,
      source: .mg, songmid: songId,
      albumName: ALHttp.str(o["album"]),
      interval: interval,
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: img.isEmpty ? nil : img,
      extra: ["copyrightId": cid, "albumId": ALHttp.str(o["albumId"]),
              "lrcUrl": lrcUrl, "trcUrl": ALHttp.str(o["trcUrl"]), "intervalSecs": ""]
    )
  }

  // MARK: 歌单（咪咕公开歌单端点已下线；降级为空）

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

  // MARK: 歌词（条目自带 lrcUrl → 明文 LRC；trcUrl 为翻译）

  static func musicLyric(_ music: MusicInfo) async throws -> LyricInfo {
    guard let lrcUrl = music.extra?["lrcUrl"], !lrcUrl.isEmpty else {
      throw ALSourceError.invalidResponse("咪咕歌词链接缺失")
    }
    let (data, resp) = try await ALHttp.getRaw(lrcUrl)
    guard resp.statusCode == 200,
          let text = String(data: data, encoding: .utf8),
          text.hasPrefix("[") || text.hasPrefix("[00") else {
      throw ALSourceError.invalidResponse("咪咕歌词获取失败")
    }
    var tlyric: String? = nil
    if let trcUrl = music.extra?["trcUrl"], !trcUrl.isEmpty,
       let (tData, tResp) = try? await ALHttp.getRaw(trcUrl), tResp.statusCode == 200,
       let tText = String(data: tData, encoding: .utf8), !tText.isEmpty {
      tlyric = tText
    }
    return LyricInfo(lyric: text, tlyric: tlyric, rlyric: nil, lxlyric: nil)
  }

  // MARK: 封面（条目自带 img；musicPic 由搜索结果 picUrl 直接满足）

  static func musicPic(_ music: MusicInfo) async -> String? {
    music.picUrl
  }

  // MARK: 播放直链（mg 无公开直链；对标 any-listen 由 LX 自定义源提供）

  static func musicUrl(_ music: MusicInfo, chain: [Int]) async -> ALMusicUrlInfo? { nil }
}
