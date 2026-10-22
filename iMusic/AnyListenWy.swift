import Foundation

// MARK: - 网易云解析（AnyListenWy）
//
// 按 any-listen 契约实现的网易源资源动作（全部端点已实测可用）：
//   musicSearch   eapi /api/search/song/list/page（签名复用 iMusicSign.wyEapiParams）
//                 + 明文 /api/search/get 兜底（eapi 波动时降级）
//   hotSearch     /api/hotsearchlist/get
//   歌单 tags     /api/playlist/catalogue（all + sub 分组）
//   歌单 list     /api/playlist/list?cat=&order=&offset=&limit=
//   歌单 search   /api/search/get?type=1000
//   歌单 detail   /api/playlist/detail?id=（tracks + 歌单信息；分页为切片）
//   topSongs      网易榜 = 官方歌单（any-listen 生态对网易榜单的处理方式）
//   lyric         eapi /api/song/lyric/v1（lrc/tlyric/romalrc）
//   pic           搜索自带 picUrl（升采样 ?param=500y500，GD音乐台同款）
//   url 兜底      GD音乐台 types=url（与 any-listen GD音乐台扩展同源）

enum AnyListenWy {
  // MARK: 搜索

  static func musicSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    // 主路径：eapi（当前 App 同款签名，实测可用）
    if let r = try? await eapiSearch(keyword: keyword, page: page, limit: limit), !r.list.isEmpty || page > 1 {
      return r
    }
    // 兜底：明文老搜索接口
    if let r = try? await legacySearch(keyword: keyword, page: page, limit: limit), !r.list.isEmpty {
      return r
    }
    throw ALSourceError.invalidResponse("网易搜索失败")
  }

  /// eapi /api/search/song/list/page（eapi batch 宿主）
  private static func eapiSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    let params = try iMusicSign.wyEapiParams(url: "/api/search/song/list/page", object: [
      "keyword": keyword, "needCorrect": "1", "channel": "typing",
      "offset": limit * (page - 1), "scene": "normal", "total": page == 1, "limit": limit,
    ])
    let json = try await iMusicHttp.postForm("http://interface.music.163.com/eapi/batch", form: ["params": params],
      headers: ["User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
                "origin": "https://music.163.com"]) as? [String: Any]
    guard let code = json?["code"] as? Int, code == 200,
          let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("网易搜索响应异常")
    }
    let resources = data["resources"] as? [[String: Any]] ?? []
    let total = ALHttp.int(data["totalCount"]) ?? resources.count
    let list = resources.compactMap(mapSimpleSong)
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  /// eapi 搜索条目（baseInfo.simpleSongData + privilege 音质段）
  private static func mapSimpleSong(_ w: [String: Any]) -> MusicInfo? {
    guard let item = (w["baseInfo"] as? [String: Any])?["simpleSongData"] as? [String: Any],
          let songId = ALHttp.int(item["id"]) else { return nil }
    var quals: [MusicQualityType] = []
    let priv = item["privilege"] as? [String: Any] ?? [:]
    if (priv["maxBrLevel"] as? String) == "hires" {
      quals.append(.init(type: .flac24bit, size: iMusicSign.size(ALHttp.double((item["hr"] as? [String: Any])?["size"]))))
    }
    switch ALHttp.int(priv["maxbr"]) ?? 128000 {
    case 999000: quals.append(.init(type: .flac, size: iMusicSign.size(ALHttp.double((item["sq"] as? [String: Any])?["size"])))); fallthrough
    case 320000: quals.append(.init(type: .q320k, size: iMusicSign.size(ALHttp.double((item["h"] as? [String: Any])?["size"])))); fallthrough
    default: quals.append(.init(type: .q128k, size: iMusicSign.size(ALHttp.double((item["l"] as? [String: Any])?["size"]))))
    }
    quals.reverse()
    let ar = (item["ar"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "、")
    let al = item["al"] as? [String: Any] ?? [:]
    let ms = ALHttp.int(item["dt"]) ?? 0
    return MusicInfo(
      name: ALHttp.str(item["name"]), singer: ar,
      source: .wy, songmid: "\(songId)",
      albumName: ALHttp.str(al["name"]),
      interval: iMusicSign.mmss(ms / 1000),
      qualitys: quals,
      picUrl: al["picUrl"] as? String
    )
  }

  /// 明文老搜索接口兜底（result.songs，免签名）
  private static func legacySearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    let q = ALHttp.query([("s", keyword), ("type", "1"), ("offset", "\(limit * (page - 1))"), ("limit", "\(limit)")])
    let json = try await ALHttp.getJSON("https://music.163.com/api/search/get?\(q)",
      headers: ["Referer": "https://music.163.com"]) as? [String: Any]
    guard let code = json?["code"] as? Int, code == 100,
          let result = json?["result"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("网易搜索响应异常")
    }
    let songs = result["songs"] as? [[String: Any]] ?? []
    let total = ALHttp.int(result["songCount"]) ?? songs.count
    let list = songs.compactMap(mapLegacySong)
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  private static func mapLegacySong(_ t: [String: Any]) -> MusicInfo? {
    guard let songId = ALHttp.int(t["id"]) else { return nil }
    var quals: [MusicQualityType] = []
    if t["hrMusic"] is [String: Any] { quals.append(.init(type: .flac24bit, size: iMusicSign.size(ALHttp.double((t["hrMusic"] as? [String: Any])?["size"])))) }
    if t["sqMusic"] is [String: Any] { quals.append(.init(type: .flac, size: iMusicSign.size(ALHttp.double((t["sqMusic"] as? [String: Any])?["size"])))) }
    if t["hMusic"] is [String: Any] { quals.append(.init(type: .q320k, size: iMusicSign.size(ALHttp.double((t["hMusic"] as? [String: Any])?["size"])))) }
    quals.append(.init(type: .q128k, size: iMusicSign.size(ALHttp.double((t["lMusic"] as? [String: Any])?["size"]))))
    let ar = (t["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "、")
    let al = t["album"] as? [String: Any] ?? [:]
    let ms = ALHttp.int(t["duration"]) ?? 0
    return MusicInfo(
      name: ALHttp.str(t["name"]), singer: ar,
      source: .wy, songmid: "\(songId)",
      albumName: ALHttp.str(al["name"]),
      interval: iMusicSign.mmss(ms / 1000),
      qualitys: quals,
      picUrl: al["picUrl"] as? String
    )
  }

  // MARK: 热搜

  static func hotSearch() async throws -> [String] {
    let json = try await ALHttp.getJSON("https://music.163.com/api/hotsearchlist/get",
      headers: ["Referer": "https://music.163.com"]) as? [String: Any]
    let data = json?["data"] as? [[String: Any]] ?? []
    return data.compactMap { $0["searchWord"] as? String }
  }

  // MARK: 歌单（tags / list / search / detail）

  static func songlistTags() async -> ALSonglistTagResult {
    guard let json = try? await ALHttp.getJSON("https://music.163.com/api/playlist/catalogue",
      headers: ["Referer": "https://music.163.com"]) as? [String: Any] else {
      return ALSonglistTagResult(tags: [], hotTags: [])
    }
    var groups: [ALTagGroupItem] = []
    for sub in (json["sub"] as? [[String: Any]]) ?? [] {
      let name = ALHttp.str(sub["name"])
      guard !name.isEmpty else { continue }
      groups.append(ALTagGroupItem(name: name, list: [ALTagItem(id: name, name: name)]))
    }
    return ALSonglistTagResult(tags: groups, hotTags: groups.flatMap(\.list).prefix(10).map { $0 })
  }

  static func songlistSorts() async -> [ALTagItem] {
    [ALTagItem(id: "hot", name: "最热"), ALTagItem(id: "new", name: "最新")]
  }

  static func songlist(sort: String, tag: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    let cat = tag.isEmpty ? "全部" : tag
    let order = sort == "new" ? "new" : "hot"
    let q = ALHttp.query([("cat", cat), ("order", order),
                          ("offset", "\(limit * (page - 1))"), ("limit", "\(limit)")])
    let json = try await ALHttp.getJSON("https://music.163.com/api/playlist/list?\(q)",
      headers: ["Referer": "https://music.163.com"]) as? [String: Any]
    let playlists = json?["playlists"] as? [[String: Any]] ?? []
    let total = ALHttp.int(json?["total"]) ?? playlists.count
    let list = playlists.map { p in
      ALSongListItem(id: ALHttp.str(p["id"]), name: ALHttp.str(p["name"]),
                     playCount: ALNormalize.playCount(p["playCount"]),
                     author: p["creator"] as? String,
                     img: (p["coverImgUrl"] as? String) ?? (p["picUrl"] as? String),
                     desc: p["description"] as? String,
                     total: ALHttp.int(p["trackCount"]))
    }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  static func songlistSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    let q = ALHttp.query([("s", keyword), ("type", "1000"), ("offset", "\(limit * (page - 1))"), ("limit", "\(limit)")])
    let json = try await ALHttp.getJSON("https://music.163.com/api/search/get?\(q)",
      headers: ["Referer": "https://music.163.com"]) as? [String: Any]
    let result = json?["result"] as? [String: Any] ?? [:]
    let playlists = result["playlists"] as? [[String: Any]] ?? []
    let total = ALHttp.int(result["playlistCount"]) ?? playlists.count
    let list = playlists.map { p in
      ALSongListItem(id: ALHttp.str(p["id"]), name: ALHttp.str(p["name"]),
                     playCount: ALNormalize.playCount(p["playCount"]),
                     author: (p["creator"] as? [String: Any]).map { ALHttp.str($0["nickname"]) },
                     img: p["coverImgUrl"] as? String,
                     desc: p["description"] as? String,
                     total: ALHttp.int(p["trackCount"]))
    }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  static func songlistDetail(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    let json = try await ALHttp.getJSON("https://music.163.com/api/playlist/detail?id=\(id)",
      headers: ["Referer": "https://music.163.com"]) as? [String: Any]
    guard let code = json?["code"] as? Int, code == 200,
          let result = json?["result"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("网易歌单详情失败")
    }
    let info = ALSongListDetailInfo(
      name: ALHttp.str(result["name"]),
      img: result["coverImgUrl"] as? String,
      desc: result["description"] as? String,
      author: (result["creator"] as? [String: Any]).map { ALHttp.str($0["nickname"]) },
      playCount: ALNormalize.playCount(result["playCount"]),
      date: nil)
    let allTracks = result["tracks"] as? [[String: Any]] ?? []
    let total = allTracks.count
    let slice = allTracks.dropFirst((page - 1) * limit).prefix(limit)
    let list = slice.compactMap(mapLegacySong)
    return ALSonglistDetailResult(list: list, total: total, page: page, limit: limit, info: info)
  }

  // MARK: 排行榜（网易榜 = 官方歌单；any-listen 生态对 wy 榜单的通用做法）

  /// 官方榜歌单 id（与 Boards.swift 主页目录同源；热歌/飙升/新歌/原创/古典/电音）
  static let boards: [(id: String, name: String)] = [
    ("3778678", "热歌榜"), ("19723756", "飙升榜"), ("3779629", "新歌榜"),
    ("2884035", "原创榜"), ("10520166", "电音榜"), ("71385702", "古典榜"),
  ]

  static func topSongs() async -> [ALTopSongsItem] {
    boards.map { b in ALTopSongsItem(id: b.id, name: b.name, pic: nil) }
  }

  static func topSongsDetail(id: String, page: Int, limit: Int) async throws -> ALTopSongsDetailResult {
    let r = try await songlistDetail(id: id, page: page, limit: limit)
    return ALTopSongsDetailResult(list: r.list, total: r.total, page: r.page, limit: r.limit,
      info: ALTopSongsDetailInfo(name: r.info.name, pic: r.info.img, desc: r.info.desc, date: r.info.date))
  }

  // MARK: 歌词（eapi /api/song/lyric/v1：lrc + 翻译 + 罗马音）

  static func musicLyric(_ music: MusicInfo) async throws -> LyricInfo {
    let params = try iMusicSign.wyEapiParams(url: "/api/song/lyric/v1", object: [
      "id": Int(music.songmid) ?? 0, "cp": false, "tv": 0, "lv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0,
    ])
    let json = try await iMusicHttp.postForm("https://interface3.music.163.com/eapi/song/lyric/v1", form: ["params": params],
      headers: ["User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
                "origin": "https://music.163.com"]) as? [String: Any]
    guard let code = json?["code"] as? Int, code == 200,
          let lrc = (json?["lrc"] as? [String: Any])?["lyric"] as? String, !lrc.isEmpty else {
      throw ALSourceError.invalidResponse("网易歌词获取失败")
    }
    func fix(_ s: String?) -> String? {
      s?.replacingOccurrences(of: #"\[(\d{2}:\d{2}):(\d{2})\]"#, with: "[$1.$2]", options: .regularExpression)
    }
    return LyricInfo(lyric: fix(lrc) ?? lrc,
                     tlyric: fix((json?["tlyric"] as? [String: Any])?["lyric"] as? String),
                     rlyric: fix((json?["romalrc"] as? [String: Any])?["lyric"] as? String),
                     lxlyric: nil)
  }

  // MARK: 封面（picUrl 升采样，GD音乐台同款 ?param=500y500）

  static func musicPic(_ music: MusicInfo) async -> String? {
    guard let u = music.picUrl, !u.isEmpty else { return nil }
    if u.contains("music.126.net"), u.contains("?") == false {
      return u + "?param=500y500"
    }
    return u
  }

  // MARK: 播放直链兜底（GD音乐台；主路径自定义源）

  static func musicUrl(_ music: MusicInfo, chain: [Int]) async -> ALMusicUrlInfo? {
    await AnyListenGD.url(source: .wy, musicId: music.songmid, chain: chain)
  }
}
