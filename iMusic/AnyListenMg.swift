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
    // 先取线上榜目录（rank-index/v1.0），失败回退静态 9 榜（对标 online-metadata mg/topSongs）
    if let json = try? await ALHttp.getJSON(
      "https://app.c.nf.migu.cn/pc/bmw/rank/rank-index/v1.0",
      headers: mgWebHeaders) as? [String: Any],
      (json["code"] as? String) == "000000",
      let data = json["data"] as? [String: Any] {
      var out: [ALTopSongsItem] = []
      var seen = Set<String>()
      for content in data["contents"] as? [[String: Any]] ?? [] {
        for item in content["contents"] as? [[String: Any]] ?? [] {
          guard let rid = item["rankId"] as? String, !seen.contains(rid) else { continue }
          seen.insert(rid)
          out.append(ALTopSongsItem(id: rid, name: item["rankName"] as? String ?? "",
                                    pic: item["imageUrl"] as? String))
        }
      }
      if !out.isEmpty { return out }
    }
    // 静态兜底（9 榜，与 online-metadata boardList 一致）
    return Self.mgStaticBoards
  }

  /// 静态榜目录兜底（对齐 online-metadata mg/topSongs.ts boardList）
  private static let mgStaticBoards: [ALTopSongsItem] = [
    .init(id: "75959118", name: "音乐风向榜", pic: "https://d.musicapp.migu.cn/data/oss/column/00/1w/w7/913ca325104448e7a019b6c3f9ec4874.webp"),
    .init(id: "76557036", name: "彩铃分贝榜", pic: "https://d.musicapp.migu.cn/data/oss/column/00/1w/w7/6bfcc5b221404d00a84fa70576f35655.webp"),
    .init(id: "76557745", name: "会员臻爱榜", pic: "https://d.musicapp.migu.cn/data/oss/column/00/1w/w7/61ee20c3cea148168405ca9ddbf93807.webp"),
    .init(id: "23189800", name: "港台榜", pic: "https://d.musicapp.migu.cn/data/oss/column/00/1w/w7/529556c1b7a5450c8a8a77fc17b6da00.webp"),
    .init(id: "23189399", name: "内地榜", pic: "https://d.musicapp.migu.cn/data/oss/column/00/1w/w6/72b0840d1c84402eb25d59e5f0257b20.webp"),
    .init(id: "83176390", name: "国风热歌榜", pic: "https://d.musicapp.migu.cn/data/oss/resource/00/5s/8y/67eabab4110847809d319eefe5794cbd.webp"),
    .init(id: "27553319", name: "新歌榜", pic: "https://d.musicapp.migu.cn/data/oss/resource/00/5s/8y/67eabab4110847809d319eefe5794cbd.webp"),
    .init(id: "27186466", name: "热歌榜", pic: "https://d.musicapp.migu.cn/data/oss/resource/00/4t/9y/a64e69c4d8c54f59b580b1a25ae5ceb3.webp"),
    .init(id: "27553408", name: "原创榜", pic: "https://d.musicapp.migu.cn/data/oss/resource/00/5l/hn/52e4c5c1862347928827e9f00cfada1a.webp"),
  ]

  /// 咪咕 Web 公共请求头（对标 online-metadata mg defaultHeaders）
  private static let mgWebHeaders: [String: String] = [
    "Referer": "https://app.c.nf.migu.cn/",
    "User-Agent": "Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36",
    "channel": "0146921",
  ]

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

  // MARK: 歌单（原生迁移自 online-metadata mg/songlist.ts；标签/列表/详情/搜索均实测可用）

  /// 歌单标签（musiclistplaza-taglist/release → 分组 + 热门标签）
  static func songlistTags() async -> ALSonglistTagResult {
    guard let json = try? await ALHttp.getJSON(
      "https://app.c.nf.migu.cn/pc/v1.0/template/musiclistplaza-taglist/release",
      headers: mgWebHeaders) as? [String: Any],
      (json["code"] as? String) == "000000",
      let data = json["data"] as? [[String: Any]], !data.isEmpty else {
      return ALSonglistTagResult(tags: [], hotTags: [])
    }
    // 首组 → 热门标签（texts[0]=name, texts[1]=id）
    let firstGroup = data[0]
    let hotTags = ((firstGroup["content"] as? [[String: Any]]) ?? []).compactMap { c -> ALTagItem? in
      guard let texts = c["texts"] as? [Any], texts.count >= 2,
            let name = texts[0] as? String, let id = texts[1] as? String, !name.isEmpty, !id.isEmpty else { return nil }
      return ALTagItem(id: id, name: name)
    }
    // 其余组 → 分组标签
    var groups: [ALTagGroupItem] = []
    for g in data.dropFirst() {
      let header = (g["header"] as? [String: Any])?["title"] as? String ?? ""
      let list = ((g["content"] as? [[String: Any]]) ?? []).compactMap { c -> ALTagItem? in
        guard let texts = c["texts"] as? [Any], texts.count >= 2,
              let name = texts[0] as? String, let id = texts[1] as? String, !name.isEmpty, !id.isEmpty else { return nil }
        return ALTagItem(id: id, name: name)
      }
      if !list.isEmpty { groups.append(ALTagGroupItem(name: header, list: list)) }
    }
    return ALSonglistTagResult(tags: groups, hotTags: hotTags)
  }

  static func songlistSorts() async -> [ALTagItem] {
    [ALTagItem(id: "15127315", name: "推荐")]
  }

  /// 按标签浏览（musiclistplaza-listbytag）或推荐（playlist-square-recommend）
  static func songlist(sort: String, tag: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    let url: String
    if !tag.isEmpty {
      url = "https://app.c.nf.migu.cn/pc/v1.0/template/musiclistplaza-listbytag/release?pageNumber=\(page)&templateVersion=2&tagId=\(tag)"
    } else {
      url = "https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0?templateVersion=2&pageNo=\(page)"
    }
    let json = try await ALHttp.getJSON(url, headers: mgWebHeaders) as? [String: Any]
    guard (json?["code"] as? String) == "000000", let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("咪咕歌单失败")
    }
    var list: [ALSongListItem] = []
    if !tag.isEmpty {
      // listbytag：contentItemList[1].itemList
      let groups = data["contentItemList"] as? [[String: Any]] ?? []
      let items = groups.count >= 2 ? (groups[1]["itemList"] as? [[String: Any]] ?? []) : []
      list = items.compactMap { it in
        let logEvent = it["logEvent"] as? [String: Any] ?? [:]
        let barList = it["barList"] as? [[String: Any]] ?? []
        return ALSongListItem(id: ALHttp.str(logEvent["contentId"]),
                              name: ALHttp.str(it["title"]),
                              playCount: barList.first?["title"] as? String,
                              img: it["imageUrl"] as? String)
      }
    } else {
      // recommend：递归收集 resType=="2021" 且去重
      list = Self.walkRecommend(data["contents"] as? [[String: Any]] ?? [])
    }
    return ALListResult(list: list, total: list.count, page: page, limit: list.count)
  }

  /// 递归收集推荐歌单（resType == "2021"，按 resId 去重）
  private static func walkRecommend(_ contents: [[String: Any]]) -> [ALSongListItem] {
    var out: [ALSongListItem] = []
    var seen = Set<String>()
    func walk(_ items: [[String: Any]]) {
      for item in items {
        if let sub = item["contents"] as? [[String: Any]], !sub.isEmpty {
          walk(sub); continue
        }
        guard (item["resType"] as? String) == "2021",
              let rid = item["resId"] as? String, !seen.contains(rid) else { continue }
        seen.insert(rid)
        out.append(ALSongListItem(id: rid, name: ALHttp.str(item["txt"]).isEmpty ? "Unknown" : ALHttp.str(item["txt"]),
                                  img: item["img"] as? String, desc: item["txt2"] as? String))
      }
    }
    walk(contents)
    return out
  }

  /// 歌单搜索（jadeite searchAll，searchSwitch songlist=1 签名）
  static func songlistSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    let time = "\(Int(Date().timeIntervalSince1970 * 1000))"
    let sig = iMusicSign.mgSign(time: time, keyword: keyword)
    let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
    let url = "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=1&isCopyright=1&searchSwitch=%7B%22song%22%3A0%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A0%2C%22mvSong%22%3A0%2C%22bestShow%22%3A0%2C%22songlist%22%3A1%2C%22lyricSong%22%3A0%7D&pageSize=\(limit)&text=\(q)&pageNo=\(page)&sort=0&sid=USS"
    let json = try await ALHttp.getJSON(url, headers: [
      "uiVersion": "A_music_3.6.1", "deviceId": sig.deviceId, "timestamp": time, "sign": sig.sign,
      "channel": "0146921",
      "User-Agent": "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30",
    ]) as? [String: Any]
    guard (json?["code"] as? String) == "000000",
          let songlistData = json?["songListResultData"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("咪咕歌单搜索失败")
    }
    let total = ALHttp.int(songlistData["totalCount"]) ?? 0
    let list = ((songlistData["result"] as? [[String: Any]]) ?? []).map { item in
      ALSongListItem(id: ALHttp.str(item["id"]), name: ALHttp.str(item["name"]),
                     playCount: ALNormalize.playCount(ALHttp.int(item["playNum"]) ?? 0),
                     author: item["userName"] as? String, time: "",
                     img: item["musicListPicUrl"] as? String,
                     desc: ALHttp.str(item["intro"]).isEmpty ? nil : ALHttp.str(item["intro"]),
                     total: ALHttp.int(item["musicNum"]) ?? 0)
    }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  /// 歌单详情（playlist/v2.0 信息 + playlist/song/v2.0 歌曲）
  static func songlistDetail(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    let infoUrl = "https://c.musicapp.migu.cn/MIGUM3.0/resource/playlist/v2.0?playlistId=\(id)"
    let infoJson = try await ALHttp.getJSON(infoUrl, headers: mgWebHeaders) as? [String: Any]
    guard (infoJson?["code"] as? String) == "000000",
          let infoData = infoJson?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("咪咕歌单详情失败")
    }
    let songUrl = "https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0?pageNo=\(page)&pageSize=\(limit)&playlistId=\(id)"
    let songJson = try await ALHttp.getJSON(songUrl, headers: mgWebHeaders) as? [String: Any]
    guard (songJson?["code"] as? String) == "000000",
          let songData = songJson?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("咪咕歌单歌曲失败")
    }
    let rawSongs = songData["songList"] as? [[String: Any]] ?? []
    let list = Self.mapSonglistSongs(rawSongs)
    let total = ALHttp.int(songData["totalCount"]) ?? list.count
    let opNum = (infoData["opNumItem"] as? [String: Any]) ?? [:]
    let imgItem = (infoData["imgItem"] as? [String: Any]) ?? [:]
    let info = ALSongListDetailInfo(
      name: ALHttp.str(infoData["title"]),
      img: imgItem["img"] as? String,
      desc: infoData["summary"] as? String,
      author: infoData["ownerName"] as? String,
      playCount: ALNormalize.playCount(ALHttp.int(opNum["playNum"]) ?? 0),
      date: nil)
    return ALSonglistDetailResult(list: list, total: total, page: page, limit: limit, info: info)
  }

  /// 歌单歌曲条目（audioFormats 音质；对标 online-metadata buildMusicInfoListV5）
  private static func mapSonglistSongs(_ raw: [[String: Any]]) -> [MusicInfo] {
    var out: [MusicInfo] = []
    var seen = Set<String>()
    for item in raw {
      guard let sid = item["songId"] as? String, !sid.isEmpty, seen.insert(sid).inserted else { continue }
      var quals: [MusicQualityType] = []
      for t in (item["audioFormats"] as? [[String: Any]] ?? []) {
        let size = iMusicSign.size(t["isize"] ?? t["asize"])
        switch t["formatType"] as? String {
        case "PQ": quals.append(.init(type: .q128k, size: size))
        case "HQ": quals.append(.init(type: .q320k, size: size))
        case "SQ": quals.append(.init(type: .flac, size: size))
        case "ZQ", "ZQ24": quals.append(.init(type: .flac24bit, size: size))
        default: break
        }
      }
      var img = ALHttp.str(item["img3"]).isEmpty ? ALHttp.str(item["img2"]) : ALHttp.str(item["img3"])
      if img.isEmpty { img = ALHttp.str(item["img1"]) }
      if !img.isEmpty && !img.hasPrefix("http") { img = "http://d.musicapp.migu.cn" + img }
      let singers: String = {
        if let arr = item["singerList"] as? [[String: Any]] { return iMusicSign.singerNames(arr) }
        if let arr = item["singerList"] as? [String] { return arr.joined(separator: "、") }
        return ALHttp.str(item["singer"])
      }()
      let secs = ALHttp.int(item["duration"]) ?? 0
      out.append(MusicInfo(
        name: ALHttp.str(item["songName"]), singer: singers,
        source: .mg, songmid: sid,
        albumName: ALHttp.str(item["album"]),
        interval: secs > 0 ? iMusicSign.mmss(secs) : nil,
        qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
        picUrl: img.isEmpty ? nil : img,
        extra: ["copyrightId": ALHttp.str(item["copyrightId"]),
                "albumId": ALHttp.str(item["albumId"]),
                "lrcUrl": ALHttp.str(item["lrcUrl"]), "trcUrl": ALHttp.str(item["trcUrl"]),
                "intervalSecs": "\(secs)"]))
    }
    return out
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

  // MARK: 热搜词（jadeite hotword；原生迁移自 online-metadata mg/hotSearch）

  static func hotSearch() async throws -> [String] {
    let json = try await ALHttp.getJSON(
      "http://jadeite.migu.cn:7090/music_search/v3/search/hotword") as? [String: Any]
    guard (json?["code"] as? String) == "000000",
          let data = json?["data"] as? [String: Any],
          let hotwords = data["hotwords"] as? [[String: Any]],
          let list = hotwords.first?["hotwordList"] as? [[String: Any]] else {
      throw ALSourceError.invalidResponse("咪咕热词失败")
    }
    return list.filter { ($0["resourceType"] as? String) == "song" }
      .compactMap { $0["word"] as? String }
  }

  // MARK: 搜索提示（tone_search_suggest；原生迁移自 online-metadata mg/tipSearch）

  static func tipSearch(keyword: String) async throws -> [String] {
    let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
    let json = try await ALHttp.getJSON(
      "https://app.u.nf.migu.cn/pc/resource/content/tone_search_suggest/v1.0?text=\(q)",
      headers: ["User-Agent": "MGMobileMusic/7.33.0 (iPhone; iOS 16.6; Scale/3.00)", "channel": "0146921"]) as? [String: Any]
    guard (json?["code"] as? String) == "000000",
          let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("咪咕搜索提示失败")
    }
    var result = Set<String>()
    for s in data["singerList"] as? [[String: Any]] ?? [] {
      if let n = s["singerName"] as? String { result.insert(n) }
    }
    for s in data["songList"] as? [[String: Any]] ?? [] {
      if let n = s["songName"] as? String { result.insert(n) }
    }
    return Array(result)
  }

  // MARK: 评论（MIGUM3.0 user/comment/stack；原生迁移自 online-metadata mg/musicComment）
  // type: "hot" | "new" | "reply"（reply 需 music 的 commentId 作 id）

  /// 翻页游标：songId → page → commentId（new 类型分页用）
  private static let commentLock = NSLock()
  nonisolated(unsafe) private static var commentCursors: [String: [Int: String]] = [:]

  private static func cursorGet(_ songId: String) -> [Int: String] {
    commentLock.lock(); defer { commentLock.unlock() }
    return commentCursors[songId] ?? [:]
  }
  private static func cursorSet(_ songId: String, _ map: [Int: String]) {
    commentLock.lock(); defer { commentLock.unlock() }
    commentCursors[songId] = map
  }

  static func musicComment(music: MusicInfo, type: String, page: Int, limit: Int = 20) async throws -> ALMusicCommentResult {
    let songId = music.songmid
    let commentHeaders = ["User-Agent":
      "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1"]
    switch type {
    case "new":
      var cursorMap = cursorGet(songId)
      if page == 1 { cursorMap.removeAll() }
      let commentId = cursorMap[page] ?? ""
      if page > 1 && commentId.isEmpty { throw ALSourceError.invalidResponse("咪咕评论翻页失败") }
      let url = "https://app.c.nf.migu.cn/MIGUM3.0/user/comment/stack/v1.0?pageSize=\(limit)&queryType=1&resourceId=\(songId)&resourceType=2&commentId=\(commentId)"
      let json = try await ALHttp.getJSON(url, headers: commentHeaders) as? [String: Any]
      guard (json?["code"] as? String) == "000000",
            let data = (json?["data"] as? [String: Any]) else {
        throw ALSourceError.invalidResponse("咪咕评论失败")
      }
      let list = Self.filterComment(data["comments"] as? [[String: Any]] ?? [])
      cursorMap[page + 1] = list.last.map { $0.id } ?? ""
      cursorSet(songId, cursorMap)
      return ALMusicCommentResult(list: list, total: ALHttp.int(data["commentNums"]) ?? 0, limit: limit, page: page)
    case "hot":
      let url = "https://app.c.nf.migu.cn/MIGUM3.0/user/comment/stack/v1.0?pageSize=\(limit)&queryType=2&resourceId=\(songId)&resourceType=2&hotCommentStart=\((page - 1) * limit)"
      let json = try await ALHttp.getJSON(url, headers: commentHeaders) as? [String: Any]
      guard (json?["code"] as? String) == "000000",
            let data = (json?["data"] as? [String: Any]) else {
        throw ALSourceError.invalidResponse("咪咕热评失败")
      }
      return ALMusicCommentResult(list: Self.filterComment(data["hotComments"] as? [[String: Any]] ?? []),
                                  total: ALHttp.int(data["cfgHotCount"]) ?? 0, limit: limit, page: page)
    case "reply":
      let replyId = music.extra?["commentId"] ?? ""
      guard !replyId.isEmpty else { throw ALSourceError.invalidResponse("咪咕回复需 commentId") }
      let url = "https://app.c.nf.migu.cn/MIGUM3.0/user/comment/stack/\(replyId)/v1.0?pageSize=\(limit)&queryType=2&resourceId=\(songId)&resourceType=2&start=\((page - 1) * limit)"
      let json = try await ALHttp.getJSON(url, headers: commentHeaders) as? [String: Any]
      guard (json?["code"] as? String) == "000000",
            let data = (json?["data"] as? [String: Any]) else {
        throw ALSourceError.invalidResponse("咪咕回复失败")
      }
      let mainItem = data["mainCommentItem"] as? [String: Any] ?? [:]
      return ALMusicCommentResult(list: Self.buildReplyItems(mainItem["replyComments"] as? [[String: Any]] ?? []),
                                  total: ALHttp.int(data["replyTotalCount"]) ?? 0, limit: limit, page: page)
    default:
      throw ALSourceError.invalidResponse("咪咕评论类型无效：\(type)")
    }
  }

  private static func buildComment(_ item: [String: Any]) -> ALMusicCommentItem? {
    guard let cid = item["commentId"] else { return nil }
    let user = item["user"] as? [String: Any] ?? [:]
    let opNum = item["opNumItem"] as? [String: Any] ?? [:]
    var c = ALMusicCommentItem(
      id: ALHttp.str(cid), userId: ALHttp.str(user["userId"]).isEmpty ? nil : ALHttp.str(user["userId"]),
      userName: ALHttp.str(user["nickName"]), text: ALHttp.str(item["commentInfo"]),
      time: ALHttp.int(item["commentTime"]), avatar: ALHttp.str(user["middleIcon"]).isEmpty
        ? (ALHttp.str(user["bigIcon"]).isEmpty ? (ALHttp.str(user["smallIcon"]).isEmpty ? nil : ALHttp.str(user["smallIcon"])) : ALHttp.str(user["bigIcon"]))
        : ALHttp.str(user["middleIcon"]),
      likedCount: ALHttp.int(opNum["thumbNum"]))
    c.reply = Self.buildReplyItems(item["replyComments"] as? [[String: Any]] ?? [])
    return c
  }

  private static func buildReplyItems(_ items: [[String: Any]]) -> [ALMusicCommentItem] {
    items.compactMap { r in
      let user = r["user"] as? [String: Any] ?? [:]
      return ALMusicCommentItem(
        id: ALHttp.str(r["replyId"]), userId: ALHttp.str(user["userId"]).isEmpty ? nil : ALHttp.str(user["userId"]),
        userName: ALHttp.str(user["nickName"]), text: ALHttp.str(r["replyInfo"]),
        time: ALHttp.int(r["replyTime"]), avatar: ALHttp.str(user["middleIcon"]).isEmpty
          ? (ALHttp.str(user["bigIcon"]).isEmpty ? (ALHttp.str(user["smallIcon"]).isEmpty ? nil : ALHttp.str(user["smallIcon"])) : ALHttp.str(user["bigIcon"]))
          : ALHttp.str(user["middleIcon"]))
    }
  }

  private static func filterComment(_ raw: [[String: Any]]) -> [ALMusicCommentItem] {
    raw.compactMap { buildComment($0) }
  }
}
