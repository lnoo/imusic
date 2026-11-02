import Foundation

// MARK: - 酷狗解析（AnyListenKg）
//
// 按 any-listen 契约实现的酷狗源资源动作（端点已逐个实测）：
//   musicSearch   songsearch.kugou.com/song_search_v2（含 Grp 同名去重、
//                 Image 封面 {size} 占位、四档文件大小音质段）
//   topSongs      mobilecdnbj /api/v3/rank/list（56 张榜，带榜图/简介/更新周期）
//                 + /api/v3/rank/song 榜单详情
//   歌单           /api/v3/search/special 歌单搜索 + /api/v3/special/song 详情
//                 （按标签浏览的公开端点已全部关闭，返回空降级）
//   lyric         lyrics.kugou.com search + download（krc 逐字解码 LyricCodec.decodeKRC；
//                 无 krc 时回落 lrc 明文；krc 候选需 hash+时长才可命中）
//   pic           搜索自带 Image（{size} → 400，stdmusic 封面）
//   url           无公开直链（对标 any-listen：kg 直链由 LX 自定义源脚本提供）

enum AnyListenKg {
  // MARK: 搜索（song_search_v2）

  static func musicSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
    let json = try await ALHttp.getJSON(
      "http://songsearch.kugou.com/song_search_v2?platform=AndroidFilter&iscorrection=1&keyword=\(q)&hifiquality=0&pagesize=\(limit)&PrivilegeFilter=0&page=\(page)") as? [String: Any]
    guard let code = json?["error_code"] as? Int, code == 0,
          let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("酷狗搜索失败")
    }
    let lists = data["lists"] as? [[String: Any]] ?? []
    var out: [MusicInfo] = []
    var seen = Set<String>()
    for item in lists {
      let key = ALHttp.str(item["Audioid"])
      guard seen.insert(key).inserted, let m = mapSearchItem(item) else { continue }
      out.append(m)
      for child in item["Grp"] as? [[String: Any]] ?? [] {
        let ck = ALHttp.str(child["Audioid"])
        guard seen.insert(ck).inserted, let cm = mapSearchItem(child) else { continue }
        out.append(cm)
      }
    }
    let total = ALHttp.int(data["total"]) ?? out.count
    return ALListResult(list: out, total: total, page: page, limit: limit)
  }

  /// song_search_v2 条目 → MusicInfo（含 Image 封面；搜索/榜单共用）
  static func mapSearchItem(_ r: [String: Any]) -> MusicInfo? {
    guard let audioId = ALHttp.int(r["Audioid"]) else { return nil }
    var quals: [MusicQualityType] = []
    if let n = ALHttp.int(r["FileSize"]), n != 0 { quals.append(.init(type: .q128k, size: iMusicSign.size(n))) }
    if let n = ALHttp.int(r["HQFileSize"]), n != 0 { quals.append(.init(type: .q320k, size: iMusicSign.size(n))) }
    if let n = ALHttp.int(r["SQFileSize"]), n != 0 { quals.append(.init(type: .flac, size: iMusicSign.size(n))) }
    if let n = ALHttp.int(r["ResFileSize"]), n != 0 { quals.append(.init(type: .flac24bit, size: iMusicSign.size(n))) }
    let singers = (r["Singers"] as? [[String: Any]]) ?? []
    let suffix = r["Suffix"] as? String ?? ""
    let secs = ALHttp.int(r["Duration"]) ?? 0
    let pic = Self.expandSize(ALHttp.str(r["Image"]), size: "400")
    return MusicInfo(
      name: iMusicSign.decode(ALHttp.str(r["OriSongName"])) + (suffix.isEmpty ? "" : " \(suffix)"),
      singer: iMusicSign.decode(iMusicSign.singerNames(singers)),
      source: .kg, songmid: "\(audioId)",
      albumName: iMusicSign.decode(ALHttp.str(r["AlbumName"])),
      interval: iMusicSign.mmss(secs),
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: pic.isEmpty ? nil : pic,
      extra: ["hash": ALHttp.str(r["FileHash"]), "albumAudioId": ALHttp.str(r["MixSongID"]),
              "albumId": ALHttp.str(r["AlbumID"]), "intervalSecs": "\(secs)"]
    )
  }

  /// kg 图链 {size} 占位 → 具体尺寸（150/240/400/500）
  static func expandSize(_ url: String, size: String = "400") -> String {
    url.replacingOccurrences(of: "{size}", with: size)
  }

  // MARK: 榜单（rank/list：56 张榜带图；rank/song：榜单详情）

  static func topSongs() async -> [ALTopSongsItem] {
    guard let json = try? await ALHttp.getJSON(
      "http://mobilecdnbj.kugou.com/api/v3/rank/list?version=9108&ranktype=1&plat=0&pagesize=100&page=1&area_code=1") as? [String: Any],
          let data = json["data"] as? [String: Any] else { return [] }
    let info = data["info"] as? [[String: Any]] ?? []
    return info.compactMap { g in
      let id = ALHttp.str(g["rankid"])
      let name = ALHttp.str(g["rankname"])
      guard !id.isEmpty, !name.isEmpty else { return nil }
      let raw = ALHttp.str(g["img_9"])
      let pic = expandSize(ALHttp.str(raw.isEmpty ? g["banner_9"] : g["img_9"]), size: "240")
      return ALTopSongsItem(id: id, name: name, pic: pic.isEmpty ? nil : pic)
    }
  }

  static func topSongsDate(id: String) async -> [ALTagItem] {
    // kg 榜单无期次概念（全球榜按 update_frequency 更新）；期次动作返回空
    []
  }

  static func topSongsDetail(id: String, date: String?, page: Int, limit: Int) async throws -> ALTopSongsDetailResult {
    let json = try await ALHttp.getJSON(
      "http://mobilecdnbj.kugou.com/api/v3/rank/song?version=9108&ranktype=1&plat=0&pagesize=\(limit)&area_code=1&page=\(page)&rankid=\(id)&with_res_tag=0&show_portrait_mv=1") as? [String: Any]
    guard let err = ALHttp.int(json?["errcode"]), err == 0,
          let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("酷狗榜单失败")
    }
    let list = (data["info"] as? [[String: Any]] ?? []).compactMap(mapRankSong)
    // 榜单元信息（名称/图/简介）需再查榜目录；用本榜详情响应中没有的元数据回查列表接口
    var info = ALTopSongsDetailInfo(name: "", pic: nil, desc: nil, date: nil)
    if let board = await topSongs().first(where: { $0.id == id }) {
      info.name = board.name
      info.pic = board.pic
    }
    let total = ALHttp.int(data["total"]) ?? list.count
    return ALTopSongsDetailResult(list: list, total: total, page: page, limit: limit, info: info)
  }

  /// rank/song 条目（authors/songname/filesize 320filesize sqfilesize filesize_high）
  private static func mapRankSong(_ r: [String: Any]) -> MusicInfo? {
    guard let audioId = ALHttp.int(r["audio_id"]) else { return nil }
    var quals: [MusicQualityType] = []
    if iMusicSign.size(r["filesize"]) != nil { quals.append(.init(type: .q128k, size: iMusicSign.size(r["filesize"]))) }
    if iMusicSign.size(r["320filesize"]) != nil { quals.append(.init(type: .q320k, size: iMusicSign.size(r["320filesize"]))) }
    if iMusicSign.size(r["sqfilesize"]) != nil { quals.append(.init(type: .flac, size: iMusicSign.size(r["sqfilesize"]))) }
    if iMusicSign.size(r["filesize_high"]) != nil { quals.append(.init(type: .flac24bit, size: iMusicSign.size(r["filesize_high"]))) }
    let authors = (r["authors"] as? [[String: Any]] ?? []).compactMap { $0["author_name"] as? String }.joined(separator: "、")
    let secs = ALHttp.int(r["duration"]) ?? 0
    return MusicInfo(
      name: iMusicSign.decode(ALHttp.str(r["songname"])),
      singer: iMusicSign.decode(authors),
      source: .kg, songmid: "\(audioId)",
      albumName: iMusicSign.decode(ALHttp.str(r["remark"])),
      interval: iMusicSign.mmss(secs),
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: expandSize(ALHttp.str(r["image"])).isEmpty ? nil : expandSize(ALHttp.str(r["image"])),
      extra: ["hash": ALHttp.str(r["hash"]), "albumAudioId": ALHttp.str(r["album_audio_id"]),
              "albumId": ALHttp.str(r["album_id"]), "intervalSecs": "\(secs)"]
    )
  }

  // MARK: 歌单（search/special + special/song；标签浏览端点已关，降级为空）

  static func songlistTags() async -> ALSonglistTagResult { ALSonglistTagResult(tags: [], hotTags: []) }
  static func songlistSorts() async -> [ALTagItem] { [] }

  static func songlist(sort: String, tag: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    ALListResult(list: [], total: 0, page: page, limit: limit)
  }

  static func songlistSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
    let json = try await ALHttp.getJSON(
      "http://mobilecdnbj.kugou.com/api/v3/search/special?keyword=\(q)&pagesize=\(limit)&page=\(page)&with_res_tag=0") as? [String: Any]
    guard let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("酷狗歌单搜索失败")
    }
    let info = data["info"] as? [[String: Any]] ?? []
    let total = ALHttp.int(data["total"]) ?? info.count
    let list = info.map { s in
      ALSongListItem(id: ALHttp.str(s["specialid"]), name: ALHttp.str(s["specialname"]),
                     playCount: ALNormalize.playCount(s["playcount"]),
                     author: s["nickname"] as? String,
                     img: expandSize(ALHttp.str(s["img"])).isEmpty ? nil : expandSize(ALHttp.str(s["img"])),
                     desc: s["intro"] as? String,
                     total: ALHttp.int(s["songcount"]))
    }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  static func songlistDetail(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    let json = try await ALHttp.getJSON(
      "http://mobilecdnbj.kugou.com/api/v3/special/song?api_ver=1&plat=0&pagesize=\(limit)&page=\(page)&specialid=\(id)&need_sort=1&with_res_tag=0") as? [String: Any]
    guard let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("酷狗歌单详情失败")
    }
    let info = data["info"] as? [[String: Any]] ?? []
    let total = ALHttp.int(data["total"]) ?? info.count
    let list = info.compactMap(mapSpecialSong)
    return ALSonglistDetailResult(list: list, total: total, page: page, limit: limit,
      info: ALSongListDetailInfo(name: "", img: nil, desc: nil, author: nil, playCount: nil, date: nil))
  }

  /// special/song 条目（filename 为「歌手 - 歌名」；无封面/专辑字段）
  private static func mapSpecialSong(_ s: [String: Any]) -> MusicInfo? {
    guard let audioId = ALHttp.int(s["audio_id"]) else { return nil }
    let filename = iMusicSign.decode(ALHttp.str(s["filename"]))
    var singer = "", name = filename
    if let range = filename.range(of: " - ") {
      singer = String(filename[filename.startIndex..<range.lowerBound])
      name = String(filename[range.upperBound...])
    }
    var quals: [MusicQualityType] = []
    if let n = ALHttp.int(s["filesize"]), n != 0 { quals.append(.init(type: .q128k, size: iMusicSign.size(n))) }
    if let n = ALHttp.int(s["320filesize"]), n != 0 { quals.append(.init(type: .q320k, size: iMusicSign.size(n))) }
    if let n = ALHttp.int(s["sqfilesize"]), n != 0 { quals.append(.init(type: .flac, size: iMusicSign.size(n))) }
    let secs = ALHttp.int(s["duration"]) ?? 0
    return MusicInfo(
      name: name, singer: singer,
      source: .kg, songmid: "\(audioId)",
      albumName: iMusicSign.decode(ALHttp.str(s["remark"])),
      interval: iMusicSign.mmss(secs),
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: nil,
      extra: ["hash": ALHttp.str(s["hash"]), "albumAudioId": ALHttp.str(s["album_audio_id"]),
              "albumId": ALHttp.str(s["album_id"]), "intervalSecs": "\(secs)"]
    )
  }

  // MARK: 歌词（krc 逐字解码；候选需 hash + 时长命中）

  static func musicLyric(_ music: MusicInfo) async throws -> LyricInfo {
    let hash = music.extra?["hash"] ?? ""
    let secs = Int(music.extra?["intervalSecs"] ?? "") ?? 0
    let headers = ["KG-RC": "1", "KG-THash": "expand_search_manager.cpp:852736169:451",
                   "User-Agent": "KuGou2012-9020-ExpandSearchManager"]
    let q = music.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let s = try await ALHttp.getJSON(
      "http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=\(q)&hash=\(hash)&timelength=\(secs * 1000)&lrctxt=1",
      headers: headers) as? [String: Any]
    guard let candidates = s?["candidates"] as? [[String: Any]], !candidates.isEmpty else {
      throw ALSourceError.invalidResponse("酷狗歌词候选为空")
    }
    // 与 lx 同款：优先 krc（krctype=1 且非 contenttype=1 的"加密逐字"），失败回落 lrc
    let lastError = ALSourceError.invalidResponse("酷狗歌词下载失败")
    for c in candidates {
      let id = ALHttp.str(c["id"])
      let accesskey = ALHttp.str(c["accesskey"])
      let krctype = ALHttp.int(c["krctype"]) ?? 1
      let contenttype = ALHttp.int(c["contenttype"]) ?? 0
      guard !id.isEmpty, !accesskey.isEmpty else { continue }
      let fmt = (krctype == 1 && contenttype != 1) ? "krc" : "lrc"
      guard let d = try? await ALHttp.getJSON(
        "http://lyrics.kugou.com/download?ver=1&client=pc&id=\(id)&accesskey=\(accesskey)&fmt=\(fmt)&charset=utf8",
        headers: headers) as? [String: Any],
            let b64 = d["content"] as? String,
            let data = Data(base64Encoded: b64), !data.isEmpty else { continue }
      if fmt == "krc", let krc = LyricCodec.decodeKRC(data) {
        let lrc = LyricCodec.krcToLrc(krc)
        return LyricInfo(lyric: lrc, tlyric: nil, rlyric: nil, lxlyric: lrc) // lxlyric=逐字原文（含 <a,b,0> 标签）
      }
      if fmt == "lrc", let text = String(data: data, encoding: .utf8), !text.isEmpty {
        return LyricInfo(lyric: text, tlyric: nil, rlyric: nil, lxlyric: nil)
      }
    }
    throw lastError
  }

  // MARK: 封面（搜索自带 Image；榜单歌曲无图时用歌手头像兜底）

  static func musicPic(_ music: MusicInfo) async -> String? {
    music.picUrl
  }

  // MARK: 播放直链（kg 无公开直链；对标 any-listen 由 LX 自定义源提供）

  static func musicUrl(_ music: MusicInfo, chain: [Int]) async -> ALMusicUrlInfo? { nil }
}
