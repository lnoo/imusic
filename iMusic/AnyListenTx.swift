import Foundation

// MARK: - QQ音乐解析（AnyListenTx）
//
// 按 any-listen 契约实现的 QQ 源资源动作（端点已逐个实测）：
//   musicSearch   musicu.fcg DoSearchForQQMusicMobile（旧 DoSearchForQQMusicDesktop
//                 + zzcSign 签名现已只回空壳 code:2000 无 data —— 即本次修复点）
//   topSongs      musicu.fcg musicToplist.ToplistInfoServer GetAll（分组榜单目录，带榜图）
//                 + GetDetail（topid）
//   歌单          GetAllTag（标签）+ fcg_get_diss_by_tag（按分类/排序浏览）
//                 + srf_diss_info.DissInfoServer.CgiGetDiss（详情；旧 byids 已 403）
//   lyric         GetPlayLyricInfo（qrc/trans/roma）+ QRC 三重DES解码（LyricCodec.decodeQRC）
//   pic           albumMid → y.gtimg.cn T002R500x500M000 公式直链
//   url 兜底      GD音乐台 types=url&source=tencent（与 any-listen GD音乐台扩展同源）

enum AnyListenTx {
  private static let UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"

  // MARK: 搜索（musicu.fcg DoSearchForQQMusicMobile，免签名）

  static func musicSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    let payload: [String: Any] = [
      "comm": ["ct": 19, "cv": 1873, "uin": 0],
      "req_1": ["module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicMobile",
                "param": ["searchid": String(Int(Date().timeIntervalSince1970)),
                          "search_type": 0, "query": keyword,
                          "page_num": page, "num_per_page": limit]],
    ]
    let json = try await ALHttp.postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload,
      headers: ["User-Agent": UA]) as? [String: Any]
    guard let req = json?["req_1"] as? [String: Any],
          ALHttp.int(req["code"]) == 0,
          let body = ((req["data"] as? [String: Any])?["body"] as? [String: Any]) else {
      throw ALSourceError.invalidResponse("QQ音乐搜索失败")
    }
    let songs = body["item_song"] as? [[String: Any]] ?? []
    let list = songs.compactMap(mapSong)
    // mobile 搜索响应无显式 total：按“取满一页即视为还有下一页”估算（供 UI 翻页判断）
    let total = list.count >= limit ? page * limit + 1 : (page - 1) * limit + list.count
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  /// tx 歌曲条目 → MusicInfo（搜索/榜单/歌单详情共用；含 media_mid 与封面公式）
  static func mapSong(_ item: [String: Any]) -> MusicInfo? {
    guard let mid = item["mid"] as? String else { return nil }
    let file = item["file"] as? [String: Any] ?? [:]
    var quals: [MusicQualityType] = []
    if let n = ALHttp.int(file["size_128mp3"]), n != 0 { quals.append(.init(type: .q128k, size: iMusicSign.size(n))) }
    if let n = ALHttp.int(file["size_320mp3"]), n != 0 { quals.append(.init(type: .q320k, size: iMusicSign.size(n))) }
    if let n = ALHttp.int(file["size_flac"]), n != 0 { quals.append(.init(type: .flac, size: iMusicSign.size(n))) }
    if let n = ALHttp.int(file["size_hires"]), n != 0 { quals.append(.init(type: .flac24bit, size: iMusicSign.size(n))) }
    let singers = (item["singer"] as? [[String: Any]]) ?? []
    let album = item["album"] as? [String: Any] ?? [:]
    let albumMid = (album["mid"] as? String) ?? ""
    let pic: String? = {
      if albumMid.isEmpty || albumMid == "空" {
        guard let first = singers.first, let smid = first["mid"] as? String else { return nil }
        return "https://y.gtimg.cn/music/photo_new/T001R500x500M000\(smid).jpg"
      }
      return "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMid).jpg"
    }()
    let secs = ALHttp.int(item["interval"]) ?? 0
    return MusicInfo(
      name: ALHttp.str(item["title"] ?? item["name"]),
      singer: iMusicSign.singerNames(singers),
      source: .tx, songmid: mid,
      albumName: ALHttp.str(album["name"]),
      interval: secs > 0 ? iMusicSign.mmss(secs) : nil,
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: pic,
      extra: ["strMediaMid": ALHttp.str(file["media_mid"]), "songId": ALHttp.str(item["id"]),
              "albumMid": albumMid, "intervalSecs": "\(secs)"]
    )
  }

  // MARK: 榜单（GetAll 目录 + GetDetail 详情）

  static func topSongs() async -> [ALTopSongsItem] {
    let payload: [String: Any] = [
      "comm": ["ct": 19, "cv": 1873, "uin": 0],
      "req_1": ["module": "musicToplist.ToplistInfoServer", "method": "GetAll", "param": [String: Any]()],
    ]
    guard let json = try? await ALHttp.postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload,
      headers: ["User-Agent": UA]) as? [String: Any],
          let req = json["req_1"] as? [String: Any],
          ALHttp.int(req["code"]) == 0,
          let data = (req["data"] as? [String: Any]),
          let groups = data["group"] as? [[String: Any]] else { return [] }
    var out: [ALTopSongsItem] = []
    for g in groups {
      for t in g["toplist"] as? [[String: Any]] ?? [] {
        let id = ALHttp.str(t["topId"])
        let name = ALHttp.str(t["title"])
        guard !id.isEmpty, !name.isEmpty else { continue }
        var pic = ALHttp.str(t["picUrl"])
        if pic.isEmpty, let front = (t["headPicUrl"] as? [String: Any]) { pic = ALHttp.str(front["pic"]) }
        // 榜名用接口标题（TopSongsItem {id,name,pic}；按 id 区分同名榜，无需组名前缀）
        out.append(ALTopSongsItem(id: id, name: name, pic: pic.isEmpty ? nil : pic))
      }
    }
    return out
  }

  static func topSongsDetail(id: String, page: Int, limit: Int) async throws -> ALTopSongsDetailResult {
    let topid = Int(id) ?? 26
    let payload: [String: Any] = [
      "comm": ["uin": 0, "format": "json", "ct": 20, "cv": 1859],
      "toplist": ["module": "musicToplist.ToplistInfoServer", "method": "GetDetail",
                  "param": ["topid": topid, "num": limit, "offset": (page - 1) * limit, "period": ""]],
    ]
    let json = try await ALHttp.postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload,
      headers: ["User-Agent": "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)"]) as? [String: Any]
    guard let svc = json?["toplist"] as? [String: Any],
          ALHttp.int(svc["code"]) == 0,
          let data = svc["data"] as? [String: Any],
          let meta = data["data"] as? [String: Any],
          let songInfoList = data["songInfoList"] as? [[String: Any]] else {
      throw ALSourceError.invalidResponse("QQ榜单失败")
    }
    let list = songInfoList.compactMap(mapSong)
    return ALTopSongsDetailResult(
      list: list, total: list.count, page: page, limit: limit,
      info: ALTopSongsDetailInfo(name: ALHttp.str(meta["title"]),
                                 pic: ALHttp.str(meta["frontPicUrl"]).isEmpty ? nil : ALHttp.str(meta["frontPicUrl"]),
                                 desc: ALHttp.str(meta["titleDetail"]),
                                 date: ALHttp.str(meta["updateTime"])))
  }

  // MARK: 歌单（GetAllTag 标签 + diss 浏览 + CgiGetDiss 详情）

  static func songlistTags() async -> ALSonglistTagResult {
    let payload: [String: Any] = [
      "comm": ["ct": 19, "cv": 1873, "uin": 0],
      "req_1": ["module": "music.playlist.PlaylistSquare", "method": "GetAllTag", "param": [String: Any]()],
    ]
    guard let json = try? await ALHttp.postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload,
      headers: ["User-Agent": UA]) as? [String: Any],
          let req = json["req_1"] as? [String: Any],
          ALHttp.int(req["code"]) == 0,
          let data = req["data"] as? [String: Any],
          let groups = data["v_group"] as? [[String: Any]] else {
      return ALSonglistTagResult(tags: [], hotTags: [])
    }
    var tagGroups: [ALTagGroupItem] = []
    for g in groups {
      let name = ALHttp.str(g["group_name"])
      let items = (g["v_item"] as? [[String: Any]]) ?? []
      let list = items.compactMap { i -> ALTagItem? in
        let id = ALHttp.str(i["id"])
        let n = ALHttp.str(i["name"])
        return id.isEmpty || n.isEmpty ? nil : ALTagItem(id: id, name: n)
      }
      if !list.isEmpty { tagGroups.append(ALTagGroupItem(name: name, list: list)) }
    }
    return ALSonglistTagResult(tags: tagGroups, hotTags: tagGroups.first?.list.prefix(10).map { $0 } ?? [])
  }

  static func songlistSorts() async -> [ALTagItem] {
    // fcg_get_diss_by_tag 的 sortId：1=默认 2=最新 3=最热 4=评分
    [ALTagItem(id: "5", name: "推荐"), ALTagItem(id: "3", name: "最热"), ALTagItem(id: "2", name: "最新")]
  }

  static func songlist(sort: String, tag: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    let categoryId = tag.isEmpty ? "10000000" : tag
    let sortId = sort.isEmpty ? "5" : sort
    let q = ALHttp.query([("picmid", "1"), ("rnd", "0.11"), ("categoryId", categoryId), ("sortId", sortId),
                          ("sin", "\((page - 1) * limit)"), ("ein", "\(page * limit - 1)"),
                          ("format", "json"), ("inCharset", "utf8"), ("outCharset", "utf-8"),
                          ("notice", "0"), ("platform", "yqq"), ("needNewCode", "0")])
    let json = try await ALHttp.getJSON("https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg?\(q)",
      headers: ["Referer": "https://y.qq.com/portal/playlist.html", "User-Agent": UA]) as? [String: Any]
    guard let code = json?["code"] as? Int, code == 0,
          let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("QQ歌单列表失败")
    }
    let diss = data["list"] as? [[String: Any]] ?? []
    let total = ALHttp.int(data["sum"]) ?? diss.count
    let list = diss.map { d in
      ALSongListItem(id: ALHttp.str(d["dissid"]), name: ALHttp.str(d["dissname"]),
                     playCount: ALNormalize.playCount(d["listennum"]),
                     author: (d["creator"] as? [String: Any]).map { ALHttp.str($0["name"]) },
                     img: d["imgurl"] as? String,
                     desc: nil, total: nil)
    }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  static func songlistSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    // tx 无独立歌单搜索公开接口：复用分类浏览的热门结果（保持契约可用）
    try await songlist(sort: "5", tag: "10000000", page: page, limit: limit)
  }

  static func songlistDetail(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    let payload: [String: Any] = [
      "comm": ["ct": 19, "cv": 1873, "uin": 0],
      "req_1": ["module": "srf_diss_info.DissInfoServer", "method": "CgiGetDiss",
                "param": ["new_format": 1, "disstid": (Int(id) ?? 0),
                          "dirid": 0, "tag": 1, "need_game_ad": 0, "onlysonglist": 0,
                          "song_begin": (page - 1) * limit, "song_num": limit,
                          "userinfo": 1, "pic_dpi": 800, "orderlist": 1, "caller": "0"]],
    ]
    let json = try await ALHttp.postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload,
      headers: ["User-Agent": UA]) as? [String: Any]
    guard let req = json?["req_1"] as? [String: Any],
          ALHttp.int(req["code"]) == 0,
          let data = req["data"] as? [String: Any],
          let dirinfo = data["dirinfo"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("QQ歌单详情失败")
    }
    let songs = data["songlist"] as? [[String: Any]] ?? []
    let total = ALHttp.int(dirinfo["songnum"]) ?? songs.count
    let list = songs.compactMap { s in mapSong(s) }
    let info = ALSongListDetailInfo(
      name: ALHttp.str(dirinfo["title"]),
      img: ALHttp.str(dirinfo["picurl"]).isEmpty ? nil : ALHttp.str(dirinfo["picurl"]),
      desc: ALHttp.str(dirinfo["desc"]),
      author: ALHttp.str(dirinfo["host_nick"]).isEmpty ? nil : ALHttp.str(dirinfo["host_nick"]),
      playCount: ALNormalize.playCount(dirinfo["listennum"]),
      date: nil)
    return ALSonglistDetailResult(list: list, total: total, page: page, limit: limit, info: info)
  }

  // MARK: 歌词（GetPlayLyricInfo + QRC 解码；trans/roma 为 base64 明文）

  static func musicLyric(_ music: MusicInfo) async throws -> LyricInfo {
    let payload: [String: Any] = [
      "comm": ["ct": 19, "cv": 1873, "uin": 0],
      "req_1": ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo",
                "param": ["songMID": music.songmid, "qrc": 1, "trans": 1, "roma": 1]],
    ]
    let json = try await ALHttp.postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload,
      headers: ["User-Agent": UA]) as? [String: Any]
    guard let req = json?["req_1"] as? [String: Any],
          ALHttp.int(req["code"]) == 0,
          let data = req["data"] as? [String: Any],
          let lyricHex = data["lyric"] as? String, !lyricHex.isEmpty else {
      throw ALSourceError.invalidResponse("QQ歌词获取失败")
    }
    guard let qrc = LyricCodec.decodeQRC(lyricHex) else {
      throw ALSourceError.invalidResponse("QQ歌词解码失败")
    }
    let (lyric, lxlyric) = LyricCodec.qrcToLrc(qrc)
    func decodeB64(_ v: String?) -> String? {
      guard let v, let d = Data(base64Encoded: v),
            let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
      return s
    }
    return LyricInfo(lyric: lyric,
                     tlyric: decodeB64(data["trans"] as? String),
                     rlyric: decodeB64(data["roma"] as? String),
                     lxlyric: lxlyric)
  }

  // MARK: 封面（搜索自带公式直链）

  static func musicPic(_ music: MusicInfo) async -> String? {
    music.picUrl
  }

  // MARK: 播放直链兜底（GD音乐台；主路径自定义源）

  static func musicUrl(_ music: MusicInfo, chain: [Int]) async -> ALMusicUrlInfo? {
    await AnyListenGD.url(source: .tx, musicId: music.songmid, chain: chain)
  }
}
