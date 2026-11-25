import Foundation

// MARK: - 网易云解析（AnyListenWy）
//
// 严格对齐 extensions/online-metadata/src/onlineResource/wy/ 的解析契约：
//   musicSearch   musicSearch.ts + utils/index.ts（eapi /api/search/song/list/page，
//                 eapi 请求头 referer + origin；结果按 songmid 去重）
//                 + 明文 /api/search/get 兜底（iMusic 特有的稳健性降级，扩展无此路径）
//   hotSearch     hotSearch.ts（/api/hotsearchlist/get）
//   歌单 tags     songlist.ts getTag/getHotTag（weapi /weapi/playlist/catalogue +
//                 /weapi/playlist/hottags；HTTP 200 + body.code==200，按 categories 分组 +
//                 playlistTag.name 热门 tag；任一失败返回空，不回退 GET、不派生伪热门 tag）
//   歌单 list     songlist.ts（/api/playlist/list?cat=&order=&offset=&limit=）
//   歌单 search   songlist.ts（/api/search/get?type=1000）
//   歌单 detail   songlist.ts（weapi /weapi/v3/playlist/detail：trackIds + privileges；
//                 数量不等时按 1000/批走 weapi /weapi/v3/song/detail 补齐；GET 详情兜底）
//   topSongs      topSongs.ts（动态 weapi toplist，失败回退本地精选 6 榜）
//   lyric         lyric.ts（eapi /api/song/lyric/v1：lrc/tlyric/romalrc）
//   pic           pic.ts（任意 url 统一追加 param=500y500 升采样）
//   url 兜底      GD音乐台 types=url（iMusic 独有的兜底行为，非扩展能力）

enum AnyListenWy {
  // MARK: 搜索

  static func musicSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    return try await eapiSearch(keyword: keyword, page: page, limit: limit)
  }

  /// eapi /api/search/song/list/page（eapi batch 宿主）
  private static func eapiSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    let params = try iMusicSign.wyEapiParams(url: "/api/search/song/list/page", object: [
      "keyword": keyword, "needCorrect": "1", "channel": "typing",
      "offset": limit * (page - 1), "scene": "normal", "total": page == 1, "limit": limit,
    ])
    let json = try await iMusicHttp.postForm("http://interface.music.163.com/eapi/batch", form: ["params": params],
      headers: ["User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
                "referer": "https://music.163.com/",
                "origin": "https://music.163.com"]) as? [String: Any]
    guard let code = json?["code"] as? Int, code == 200,
          let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("网易搜索响应异常")
    }
    let resources = data["resources"] as? [[String: Any]] ?? []
    let total = ALHttp.int(data["totalCount"]) ?? resources.count
    let list = ALNormalize.dedup(resources.compactMap(mapSimpleSong)) { $0.songmid }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  /// eapi 搜索条目（baseInfo.simpleSongData + privilege 音质段）
  /// 音质档位与 wy/utils/index.ts buildMusicList 一一对应：无 default 兜底档，不 reverse。
  private static func mapSimpleSong(_ w: [String: Any]) -> MusicInfo? {
    guard let item = (w["baseInfo"] as? [String: Any])?["simpleSongData"] as? [String: Any],
          let songId = ALHttp.int(item["id"]) else { return nil }
    var quals: [MusicQualityType] = []
    let priv = item["privilege"] as? [String: Any] ?? [:]
    if (priv["maxBrLevel"] as? String) == "hires" {
      quals.append(.init(type: .flac24bit, size: ALFormat.sizeFormate((item["hr"] as? [String: Any])?["size"])))
    }
    switch ALHttp.int(priv["maxbr"]) {
    case 999000: quals.append(.init(type: .flac, size: ALFormat.sizeFormate((item["sq"] as? [String: Any])?["size"]))); fallthrough
    case 320000: quals.append(.init(type: .q320k, size: ALFormat.sizeFormate((item["h"] as? [String: Any])?["size"]))); fallthrough
    case 192000, 128000: quals.append(.init(type: .q128k, size: ALFormat.sizeFormate((item["l"] as? [String: Any])?["size"])))
    default: break // 未知 maxbr 不追加任何音质档（对齐扩展 switch 无 default）
    }
    let al = item["al"] as? [String: Any] ?? [:]
    let ms = ALHttp.int(item["dt"]) ?? 0
    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(item["name"])),
      singer: ALFormat.singerName(item["ar"]),
      source: .wy, songmid: "\(songId)",
      albumName: ALFormat.decodeName(ALHttp.str(al["name"])),
      interval: ALFormat.playTime(ms / 1000),
      qualitys: quals,
      picUrl: al["picUrl"] as? String
    )
  }

  private static func mapLegacySong(_ t: [String: Any]) -> MusicInfo? {
    guard let songId = ALHttp.int(t["id"]) else { return nil }
    var quals: [MusicQualityType] = []
    if t["hrMusic"] is [String: Any] { quals.append(.init(type: .flac24bit, size: ALFormat.sizeFormate((t["hrMusic"] as? [String: Any])?["size"]))) }
    if t["sqMusic"] is [String: Any] { quals.append(.init(type: .flac, size: ALFormat.sizeFormate((t["sqMusic"] as? [String: Any])?["size"]))) }
    if t["hMusic"] is [String: Any] { quals.append(.init(type: .q320k, size: ALFormat.sizeFormate((t["hMusic"] as? [String: Any])?["size"]))) }
    quals.append(.init(type: .q128k, size: ALFormat.sizeFormate((t["lMusic"] as? [String: Any])?["size"])))
    let al = t["album"] as? [String: Any] ?? [:]
    let ms = ALHttp.int(t["duration"]) ?? 0
    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(t["name"])),
      singer: ALFormat.singerName(t["artists"]),
      source: .wy, songmid: "\(songId)",
      albumName: ALFormat.decodeName(ALHttp.str(al["name"])),
      interval: ALFormat.playTime(ms / 1000),
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

  // MARK: 网易 weapi 私有助手（对齐 wy/utils/index.ts weapiRequest + crypto.ts weapi）
  //
  // 依赖 ALCrypto.weapiParams（原生 weapi 加密实现）；助手内部校验 HTTP 200，
  // 与扩展 weapiRequest 的 statusCode 检查对齐。

  private static func wyWeapi(_ url: String, object: [String: Any]) async throws -> [String: Any] {
    let enc = ALCrypto.weapiParams(object, url: url)
    let form: [(String, String)] = [("params", enc.params), ("encSecKey", enc.encSecKey)]
    // 与 ALHttp.postForm 一致的严格百分号编码（base64 的 + / = 不会失真）
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let body = form.map { k, v in
      let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
      let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
      return "\(ek)=\(ev)"
    }.joined(separator: "&")
    let headers = [
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
      "Referer": "https://music.163.com/",
      "Origin": "https://music.163.com",
    ]
    let (data, response) = try await ALHttp.postRaw(url, body: Data(body.utf8), headers: headers)
    guard response.statusCode == 200 else {
      throw ALSourceError.invalidResponse("网易 weapi HTTP \(response.statusCode)")
    }
    let json = try JSONSerialization.jsonObject(with: data)
    guard let dict = json as? [String: Any] else {
      throw ALSourceError.invalidResponse("网易 weapi 响应异常")
    }
    return dict
  }

  /// songlist.ts filterTagInfo：按 categories[key] 分组，组内 id/name 均为 sub 名。
  private static func wyTagGroups(_ body: [String: Any]) -> [ALTagGroupItem] {
    let subs = ALHttp.arr(body["sub"]) ?? []
    let categories = ALHttp.dict(body["categories"]) ?? [:]
    var subList: [String: [ALTagItem]] = [:]
    for sub in subs {
      let key = ALHttp.str(sub["category"])
      let name = ALHttp.str(sub["name"])
      subList[key, default: []].append(ALTagItem(id: name, name: name))
    }
    // JSONSerialization 的字典无序；以 sub 首次出现顺序近似 Object.keys(categories) 的插入序，
    // 并补齐只出现在 categories 中的 key。
    var keyOrder: [String] = []
    for sub in subs {
      let key = ALHttp.str(sub["category"])
      if categories[key] != nil && !keyOrder.contains(key) { keyOrder.append(key) }
    }
    for key in categories.keys.sorted() where !keyOrder.contains(key) { keyOrder.append(key) }
    return keyOrder.map { key in
      ALTagGroupItem(name: ALHttp.str(categories[key]), list: subList[key] ?? [])
    }
  }

  /// songlist.ts filterHotTagInfo：body.tags[].playlistTag.name
  private static func wyHotTags(_ body: [String: Any]) -> [ALTagItem] {
    (ALHttp.arr(body["tags"]) ?? []).map { item in
      let name = ALHttp.str((item["playlistTag"] as? [String: Any])?["name"])
      return ALTagItem(id: name, name: name)
    }
  }

  /// wy/utils/index.ts buildMusicList2：songs 与 privileges 按 id 对齐生成 MusicInfo。
  /// 与 mapSimpleSong 一致，不在 picUrl 上追加 param=500y500（由 musicPic 统一处理）。
  private static func wyBuildMusicList(songs: [[String: Any]], privileges: [[String: Any]]) -> [MusicInfo] {
    var privById: [String: [String: Any]] = [:]
    for p in privileges { privById[ALHttp.str(p["id"])] = p }
    return songs.enumerated().compactMap { idx, item in
      let id = ALHttp.str(item["id"])
      guard !id.isEmpty else { return nil }
      let priv = (idx < privileges.count && ALHttp.str(privileges[idx]["id"]) == id)
        ? privileges[idx] : privById[id]
      guard let priv else { return nil } // 对齐 buildMusicList2 无 privilege 则跳过

      var quals: [MusicQualityType] = []
      if ALHttp.str(priv["maxBrLevel"]) == "hires" {
        quals.append(.init(type: .flac24bit, size: ALFormat.sizeFormate((item["hr"] as? [String: Any])?["size"])))
      }
      switch ALHttp.int(priv["maxbr"]) {
      case 999000: quals.append(.init(type: .flac, size: ALFormat.sizeFormate((item["sq"] as? [String: Any])?["size"]))); fallthrough
      case 320000: quals.append(.init(type: .q320k, size: ALFormat.sizeFormate((item["h"] as? [String: Any])?["size"]))); fallthrough
      case 192000, 128000: quals.append(.init(type: .q128k, size: ALFormat.sizeFormate((item["l"] as? [String: Any])?["size"])))
      default: break
      }
      let al = item["al"] as? [String: Any] ?? [:]
      return MusicInfo(
        name: ALFormat.decodeName(ALHttp.str(item["name"])),
        singer: ALFormat.singerName(item["ar"]),
        source: .wy, songmid: id,
        albumName: ALFormat.decodeName(ALHttp.str(al["name"])),
        interval: ALFormat.playTime((ALHttp.int(item["dt"]) ?? 0) / 1000),
        qualitys: quals,
        picUrl: al["picUrl"] as? String
      )
    }
  }

  /// musicDetail.ts getList：weapi /weapi/v3/song/detail（单次最多 1000 个 id）
  private static func wyMusicDetail(ids: [String]) async throws -> [MusicInfo] {
    let numeric = ids.compactMap { ALHttp.int($0) }
    guard !numeric.isEmpty else { return [] }
    let c = "[" + numeric.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
    let idList = "[" + numeric.map(String.init).joined(separator: ",") + "]"
    let json = try await wyWeapi("https://music.163.com/weapi/v3/song/detail",
                                 object: ["c": c, "ids": idList])
    guard ALHttp.int(json["code"]) == 200 else {
      throw ALSourceError.invalidResponse("网易音乐详情失败")
    }
    return wyBuildMusicList(songs: ALHttp.arr(json["songs"]) ?? [],
                            privileges: ALHttp.arr(json["privileges"]) ?? [])
  }

  private static func wyChunks<T>(_ list: [T], size: Int) -> [[T]] {
    guard size > 0 else { return [list] }
    var out: [[T]] = []
    var cur: [T] = []
    cur.reserveCapacity(size)
    for item in list {
      cur.append(item)
      if cur.count == size { out.append(cur); cur.removeAll(keepingCapacity: true) }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
  }

  /// songlist.ts getTag：weapi /weapi/playlist/catalogue（{}），要求 HTTP 200 + body.code==200。
  private static func getTag() async throws -> [ALTagGroupItem] {
    let body = try await wyWeapi("https://music.163.com/weapi/playlist/catalogue", object: [:])
    guard ALHttp.int(body["code"]) == 200 else {
      throw ALSourceError.invalidResponse("网易歌单标签获取失败")
    }
    return wyTagGroups(body)
  }

  /// songlist.ts getHotTag：weapi /weapi/playlist/hottags（{}），要求 HTTP 200 + body.code==200。
  private static func getHotTag() async throws -> [ALTagItem] {
    let body = try await wyWeapi("https://music.163.com/weapi/playlist/hottags", object: [:])
    guard ALHttp.int(body["code"]) == 200 else {
      throw ALSourceError.invalidResponse("网易歌单热门标签获取失败")
    }
    return wyHotTags(body)
  }

  /// songlist.ts getTags：Promise.all([getTag(), getHotTag()])；任一失败即整体失败。
  /// 分发层签名非 throwing，故在外层捕获并返回空结果（不回退明文 GET、不派生伪热门 tag）。
  static func songlistTags() async -> ALSonglistTagResult {
    do {
      async let tags = getTag()
      async let hotTags = getHotTag()
      return ALSonglistTagResult(tags: try await tags, hotTags: try await hotTags)
    } catch {
      return ALSonglistTagResult(tags: [], hotTags: [])
    }
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
                     playCount: ALFormat.playCount(p["playCount"]),
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
                     playCount: ALFormat.playCount(p["playCount"]),
                     author: (p["creator"] as? [String: Any]).map { ALHttp.str($0["nickname"]) },
                     img: p["coverImgUrl"] as? String,
                     desc: p["description"] as? String,
                     total: ALHttp.int(p["trackCount"]))
    }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  static func songlistDetail(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    // 主路径（对齐 songlist.ts getListDetail）：weapi /weapi/v3/playlist/detail
    if let body = try? await wyWeapi("https://music.163.com/weapi/v3/playlist/detail",
                                     object: ["id": id, "n": limit, "s": 8]),
       ALHttp.int(body["code"]) == 200,
       let playlist = ALHttp.dict(body["playlist"]) {
      let trackIds = ALHttp.arr(playlist["trackIds"]) ?? []
      let privileges = ALHttp.arr(body["privileges"]) ?? []
      let info = ALSongListDetailInfo(
        name: ALHttp.str(playlist["name"]),
        img: playlist["coverImgUrl"] as? String,
        desc: playlist["description"] as? String,
        author: (playlist["creator"] as? [String: Any]).map { ALHttp.str($0["nickname"]) },
        playCount: ALFormat.playCount(playlist["playCount"]),
        date: nil) // 对齐扩展 info：formatPlayCount + 无 date
      let start = max(0, (page - 1) * limit)
      let list: [MusicInfo]
      if trackIds.count == privileges.count,
         let tracks = ALHttp.arr(playlist["tracks"]), !tracks.isEmpty {
        // trackIds 与 privileges 一一对齐：直接由 tracks + privileges 构建（buildMusicList2）
        list = Array(wyBuildMusicList(songs: tracks, privileges: privileges)
          .dropFirst(start).prefix(limit))
      } else {
        // 数量不一致：按 1000/批走 musicDetail（weapi /weapi/v3/song/detail）补齐
        let ids = trackIds.compactMap { ALHttp.int($0["id"]).map { String($0) } }
        var built: [MusicInfo] = []
        for batch in wyChunks(Array(ids.dropFirst(start).prefix(limit)), size: 1000) {
          built.append(contentsOf: (try? await wyMusicDetail(ids: batch)) ?? [])
        }
        list = ALNormalize.dedup(built) { $0.songmid }
      }
      return ALSonglistDetailResult(list: list, total: trackIds.count,
                                    page: page, limit: limit, info: info)
    }

    // 兜底：明文 GET /api/playlist/detail?id=（保留 iMusic 既有稳健性路径）
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
      playCount: ALFormat.playCount(result["playCount"]),
      date: nil)
    let allTracks = result["tracks"] as? [[String: Any]] ?? []
    let total = allTracks.count
    let slice = allTracks.dropFirst((page - 1) * limit).prefix(limit)
    let list = slice.compactMap(mapLegacySong)
    return ALSonglistDetailResult(list: list, total: total, page: page, limit: limit, info: info)
  }

  // MARK: 排行榜（对齐 wy/topSongs.ts getBoards：动态 weapi toplist，失败回退本地 6 榜）
  //
  // 扩展的 62 榜静态兜底不在本文件范围，保留与 Boards.swift 同源的本地精选子集。

  /// 官方榜歌单 id（与 Boards.swift 主页目录同源；热歌/飙升/新歌/原创/电音/古典）
  static let boards: [(id: String, name: String)] = [
    ("3778678", "热歌榜"), ("19723756", "飙升榜"), ("3779629", "新歌榜"),
    ("2884035", "原创榜"), ("10520166", "电音榜"), ("71385702", "古典榜"),
  ]

  static func topSongs() async -> [ALTopSongsItem] {
    // 动态 toplist（topSongs.ts:390-400）；weapi 不可用 / 请求失败时保持原有 6 榜行为
    if let json = try? await wyWeapi("https://music.163.com/weapi/toplist", object: [:]),
       ALHttp.int(json["code"]) == 200,
       let raw = ALHttp.arr(json["list"]), !raw.isEmpty {
      let items = raw.compactMap { board -> ALTopSongsItem? in
        let id = ALHttp.str(board["id"])
        guard !id.isEmpty else { return nil }
        return ALTopSongsItem(id: id, name: ALHttp.str(board["name"]),
                              pic: board["coverImgUrl"] as? String)
      }
      if !items.isEmpty { return items }
    }
    return boards.map { b in ALTopSongsItem(id: b.id, name: b.name, pic: nil) }
  }

  static func topSongsDetail(id: String, page: Int, limit: Int) async throws -> ALTopSongsDetailResult {
    let r = try await songlistDetail(id: id, page: page, limit: limit)
    return ALTopSongsDetailResult(list: r.list, total: r.total, page: r.page, limit: r.limit,
      info: ALTopSongsDetailInfo(name: r.info.name, pic: r.info.img, desc: r.info.desc, date: r.info.date))
  }

  // MARK: 歌词（对齐 wy/lyric.ts：eapi /api/song/lyric/v1：lrc + 翻译 + 罗马音）

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
    // 歌词文本按 decodeName 反转义（命名实体 / 数字实体）；YRC 逐字解析暂不在范围内。
    func fix(_ s: String?) -> String? {
      guard let s else { return nil }
      return ALFormat.decodeName(s)
    }
    return LyricInfo(lyric: fix(lrc) ?? lrc,
                     tlyric: fix((json?["tlyric"] as? [String: Any])?["lyric"] as? String),
                     rlyric: fix((json?["romalrc"] as? [String: Any])?["lyric"] as? String),
                     lxlyric: nil)
  }

  // MARK: 封面（对齐 wy/pic.ts：任意合法 http(s) url 统一追加 param=500y500 升采样）

  static func musicPic(_ music: MusicInfo) async -> String? {
    guard let u = music.picUrl, !u.isEmpty else { return nil }
    guard u.hasPrefix("http") else { return u }
    return u + (u.contains("?") ? "&" : "?") + "param=500y500"
  }

  // MARK: 播放直链兜底（iMusic 独有行为：GD音乐台 types=url；扩展无此能力，主路径自定义源）

  static func musicUrl(_ music: MusicInfo, chain: [Int]) async -> ALMusicUrlInfo? {
    await AnyListenGD.url(source: .wy, musicId: music.songmid, chain: chain)
  }
}
