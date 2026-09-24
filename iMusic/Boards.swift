import Foundation

// MARK: - 多源真实榜单（对标各源 musicSdk/*/leaderboard.js）
// 各源榜单远不止一张热歌榜：kw 官方 boardList 有 40+（飙升/新歌/抖音/华语/粤语/欧美/日韩/
// 古风/电音/DJ/影视/怀旧…），kg 有飙升6666/TOP500 8888，tx 有多个 topid，wy 是歌单型榜单。
// 本文件：各源抓取函数全部参数化（bangid/rankid/topid/歌单id）+ HomeBoards 统一目录，
// 主页按"源 -> 榜单"两级展开，加新榜只需往目录加一行。

/// 酷狗榜单（对标 kg/leaderboard.js；rankid 参数化，实测 6666/8888 可用）
enum KgBoard {
  static func hotSongs(limit: Int = 10) async throws -> [MusicInfo] {
    try await songs(rankid: "8888", limit: limit)
  }

  static func songs(rankid: String, limit: Int = 10) async throws -> [MusicInfo] {
    let json = try await iMusicHttp.getJSON(
      "http://mobilecdnbj.kugou.com/api/v3/rank/song?version=9108&ranktype=1&plat=0&pagesize=\(limit)&area_code=1&page=1&rankid=\(rankid)&with_res_tag=0&show_portrait_mv=1"
    ) as? [String: Any]
    guard let err = json?["errcode"] as? Int, err == 0,
          let list = (json?["data"] as? [String: Any])?["info"] as? [[String: Any]] else {
      throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "酷狗榜单失败"])
    }
    return list.compactMap(map)
  }

  private static func map(_ r: [String: Any]) -> MusicInfo? {
    guard let audioId = r["audio_id"] else { return nil }
    var quals: [MusicQualityType] = []
    if iMusicSign.size(r["filesize"]) != nil { quals.append(.init(type: .q128k, size: iMusicSign.size(r["filesize"]))) }
    if iMusicSign.size(r["320filesize"]) != nil { quals.append(.init(type: .q320k, size: iMusicSign.size(r["320filesize"]))) }
    if iMusicSign.size(r["sqfilesize"]) != nil { quals.append(.init(type: .flac, size: iMusicSign.size(r["sqfilesize"]))) }
    if iMusicSign.size(r["filesize_high"]) != nil { quals.append(.init(type: .flac24bit, size: iMusicSign.size(r["filesize_high"]))) }
    let authors = (r["authors"] as? [[String: Any]] ?? []).compactMap { $0["author_name"] as? String }.joined(separator: "、")
    let secs = (r["duration"] as? Int) ?? 0
    return MusicInfo(
      name: iMusicSign.decode("\(r["songname"] ?? "")"),
      singer: iMusicSign.decode(authors),
      source: .kg, songmid: "\(audioId)",
      albumName: iMusicSign.decode("\(r["remark"] ?? "")"),
      interval: iMusicSign.mmss(secs),
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      extra: ["hash": "\(r["hash"] ?? "")", "albumAudioId": "\(r["album_audio_id"] ?? "")",
              "albumId": "\(r["album_id"] ?? "")", "intervalSecs": "\(secs)"]
    )
  }
}

/// QQ 榜单（对标 tx/leaderboard.js；topid 参数化，26=热歌，实测 period 传空即可）
enum TxBoard {
  static func hotSongs(limit: Int = 10) async throws -> [MusicInfo] {
    try await songs(topid: 26, limit: limit)
  }

  static func songs(topid: Int, limit: Int = 10) async throws -> [MusicInfo] {
    let payload: [String: Any] = [
      "toplist": ["module": "musicToplist.ToplistInfoServer", "method": "GetDetail",
                  "param": ["topid": topid, "num": limit, "period": ""]],
      "comm": ["uin": 0, "format": "json", "ct": 20, "cv": 1859],
    ]
    let json = try await iMusicHttp.postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload,
      headers: ["User-Agent": "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)"]) as? [String: Any]
    guard let code = (json?["toplist"] as? [String: Any])?["code"] as? Int, code == 0,
          let list = ((json?["toplist"] as? [String: Any])?["data"] as? [String: Any])?["songInfoList"] as? [[String: Any]] else {
      throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "QQ 榜单失败"])
    }
    // 条目结构与搜索结果一致，复用 TxSearch 映射（含 strMediaMid/picUrl，供换源与封面兜底）
    return list.compactMap(TxSearch.mapSong)
  }
}

/// 网易榜单（对标 wy/leaderboard.js；歌单型榜单，playlistId 参数化，免签名直出，含完整音质段）
enum WyBoard {
  static func hotSongs(limit: Int = 10) async throws -> [MusicInfo] {
    try await songs(playlistId: "3778678", limit: limit)
  }

  static func songs(playlistId: String, limit: Int = 10) async throws -> [MusicInfo] {
    let json = try await iMusicHttp.getJSON("https://music.163.com/api/playlist/detail?id=\(playlistId)") as? [String: Any]
    guard let code = json?["code"] as? Int, code == 200,
          let tracks = (json?["result"] as? [String: Any])?["tracks"] as? [[String: Any]] else {
      throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "网易榜单失败"])
    }
    return tracks.prefix(limit).compactMap(map)
  }

  private static func map(_ t: [String: Any]) -> MusicInfo? {
    guard let songId = t["id"] else { return nil }
    var quals: [MusicQualityType] = []
    if t["hrMusic"] is [String: Any] { quals.append(.init(type: .flac24bit, size: iMusicSign.size((t["hrMusic"] as? [String: Any])?["size"]))) }
    if t["sqMusic"] is [String: Any] { quals.append(.init(type: .flac, size: iMusicSign.size((t["sqMusic"] as? [String: Any])?["size"]))) }
    if t["hMusic"] is [String: Any] { quals.append(.init(type: .q320k, size: iMusicSign.size((t["hMusic"] as? [String: Any])?["size"]))) }
    quals.append(.init(type: .q128k, size: iMusicSign.size((t["lMusic"] as? [String: Any])?["size"])))
    let ar = (t["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "、")
    let al = t["album"] as? [String: Any] ?? [:]
    let ms = (t["duration"] as? Int) ?? 0
    return MusicInfo(
      name: "\(t["name"] ?? "")", singer: ar,
      source: .wy, songmid: "\(songId)",
      albumName: "\(al["name"] ?? "")",
      interval: iMusicSign.mmss(ms / 1000),
      qualitys: quals,
      picUrl: al["picUrl"] as? String
    )
  }
}

/// 咪咕尖叫热歌榜（对标 mg/leaderboard.js bangid 27186466）
enum MgBoard {
  static func hotSongs(limit: Int = 10) async throws -> [MusicInfo] {
    let json = try await iMusicHttp.getJSON(
      "https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do?columnId=27186466&needAll=0",
      headers: ["Referer": "https://app.c.nf.migu.cn/",
                "User-Agent": "Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36",
                "channel": "0146921"]
    ) as? [String: Any]
    guard (json?["code"] as? String) == "000000",
          let contents = (json?["columnInfo"] as? [String: Any])?["contents"] as? [[String: Any]] else {
      throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "咪咕榜单失败"])
    }
    var seen = Set<String>()
    var out: [MusicInfo] = []
    for c in contents {
      guard let o = c["objectInfo"] as? [String: Any],
            let sid = o["songId"] as? String, seen.insert(sid).inserted,
            let m = map(o) else { continue }
      out.append(m)
      if out.count >= limit { break }
    }
    return out
  }

  private static func map(_ o: [String: Any]) -> MusicInfo? {
    guard let sid = o["songId"] as? String,
          let cid = o["copyrightId"] as? String else { return nil }
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
    let singers = (o["artists"] as? [[String: Any]]).map(iMusicSign.singerNames) ?? "\(o["singer"] ?? "")"
    var img = ((o["albumImgs"] as? [[String: Any]])?.first?["img"] as? String) ?? ""
    if !img.isEmpty && !img.hasPrefix("http") { img = "http://d.musicapp.migu.cn" + img }
    // length 形如 "03:45" 取尾部（对标 filterMusicInfoList）
    let length = "\(o["length"] ?? "")"
    let interval: String? = {
      guard let r = try? NSRegularExpression(pattern: #"(\d\d:\d\d)$"#),
            let m = r.firstMatch(in: length, range: NSRange(location: 0, length: (length as NSString).length)) else { return nil }
      return (length as NSString).substring(with: m.range(at: 1))
    }()
    return MusicInfo(
      name: "\(o["songName"] ?? "")", singer: singers,
      source: .mg, songmid: sid,
      albumName: "\(o["album"] ?? "")",
      interval: interval,
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: img.isEmpty ? nil : img,
      extra: ["copyrightId": cid, "albumId": "\(o["albumId"] ?? "")",
              "lrcUrl": "\(o["lrcUrl"] ?? "")", "trcUrl": "\(o["trcUrl"] ?? "")"]
    )
  }
}

// MARK: - 主页榜单目录（源 -> 榜单两级展开的唯一真相源）
// id 形如 "kw__16"（source__榜单key），与主页缓存 key 同构。
// key 的含义按源而定：kw=bangid，kg=rankid，tx=topid，wy=歌单id，mg=columnId。
// 全部用 curl/接口实测有数收录；单榜失败时按榜降级为空，不影响同源其他榜。

struct HomeBoard: Identifiable, Hashable, Sendable {
  var id: String { "\(sourceId)__\(key)" }
  var sourceId: String
  var key: String
  var name: String
  var category: String // 推荐 / 飙升 / 新歌 / 风格 / 场景
}

enum HomeBoards {
  static let all: [HomeBoard] = [
    // 酷我（kbangserver 免签名，bangid 实测均有数）
    HomeBoard(sourceId: "kw", key: "16", name: "热歌榜", category: "推荐"),
    HomeBoard(sourceId: "kw", key: "93", name: "飙升榜", category: "飙升"),
    HomeBoard(sourceId: "kw", key: "17", name: "新歌榜", category: "新歌"),
    HomeBoard(sourceId: "kw", key: "158", name: "抖音热歌榜", category: "场景"),
    HomeBoard(sourceId: "kw", key: "104", name: "华语榜", category: "风格"),
    HomeBoard(sourceId: "kw", key: "182", name: "粤语榜", category: "风格"),
    HomeBoard(sourceId: "kw", key: "22", name: "欧美榜", category: "风格"),
    HomeBoard(sourceId: "kw", key: "183", name: "日语榜", category: "风格"),
    HomeBoard(sourceId: "kw", key: "184", name: "韩语榜", category: "风格"),
    HomeBoard(sourceId: "kw", key: "278", name: "古风音乐榜", category: "风格"),
    HomeBoard(sourceId: "kw", key: "242", name: "电音榜", category: "风格"),
    HomeBoard(sourceId: "kw", key: "176", name: "DJ嗨歌榜", category: "风格"),
    HomeBoard(sourceId: "kw", key: "64", name: "影视金曲榜", category: "场景"),
    HomeBoard(sourceId: "kw", key: "26", name: "经典怀旧榜", category: "场景"),
    // 酷狗（rankid 实测有数）
    HomeBoard(sourceId: "kg", key: "8888", name: "TOP500", category: "推荐"),
    HomeBoard(sourceId: "kg", key: "6666", name: "飙升榜", category: "飙升"),
    // QQ（topid 与热歌榜同接口形态）
    HomeBoard(sourceId: "tx", key: "26", name: "热歌榜", category: "推荐"),
    HomeBoard(sourceId: "tx", key: "4", name: "流行指数榜", category: "推荐"),
    HomeBoard(sourceId: "tx", key: "27", name: "新歌榜", category: "新歌"),
    HomeBoard(sourceId: "tx", key: "28", name: "网络歌曲榜", category: "场景"),
    // 网易（歌单型榜单，与热歌榜同接口形态）
    HomeBoard(sourceId: "wy", key: "3778678", name: "热歌榜", category: "推荐"),
    HomeBoard(sourceId: "wy", key: "19723756", name: "飙升榜", category: "飙升"),
    HomeBoard(sourceId: "wy", key: "3779629", name: "新歌榜", category: "新歌"),
    HomeBoard(sourceId: "wy", key: "10520166", name: "电音榜", category: "风格"),
    // 咪咕（columnId）
    HomeBoard(sourceId: "mg", key: "27186466", name: "尖叫热歌榜", category: "推荐"),
  ]

  static let defaultSourceId = "kw"
  static let defaultBoardId = "kw__16"

  /// 有榜单的源（主页顶部资源切换器的顺序，跟随 SourceRegistry 排序）
  static var sources: [SourceCapability] {
    let ids = Set(all.map(\.sourceId))
    return SourceRegistry.withBoard.filter { ids.contains($0.id) }
  }

  static func boards(for sourceId: String) -> [HomeBoard] {
    all.filter { $0.sourceId == sourceId }
  }

  static func board(id: String) -> HomeBoard? {
    all.first { $0.id == id }
  }
}

/// 按目录抓取单榜（sourceId 分发到各源参数化函数）
enum HomeBoardFetcher {
  static func fetch(_ board: HomeBoard, limit: Int = 10) async throws -> [MusicInfo] {
    switch board.sourceId {
    case "kw": return try await KwBoard.songs(bangid: board.key, limit: limit)
    case "kg": return try await KgBoard.songs(rankid: board.key, limit: limit)
    case "tx": return try await TxBoard.songs(topid: Int(board.key) ?? 26, limit: limit)
    case "wy": return try await WyBoard.songs(playlistId: board.key, limit: limit)
    case "mg": return try await MgBoard.hotSongs(limit: limit)
    default:
      throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "未知榜单源 \(board.sourceId)"])
    }
  }
}
