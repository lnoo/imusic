import Foundation

// MARK: - 多源搜索（对标 renderer/utils/musicSdk/{kg,tx,wy,mg}/musicSearch.js）
// kw 已在 SearchService.swift。各源 handleResult 归一化到 MusicInfo，envelope/签名逐源复刻。

enum KgSearch {
  static func search(keyword: String, page: Int = 1, limit: Int = 30) async throws -> (items: [MusicInfo], total: Int) {
    let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
    let json = try await iMusicHttp.getJSON("http://songsearch.kugou.com/song_search_v2?platform=AndroidFilter&iscorrection=1&keyword=\(q)&hifiquality=0&pagesize=\(limit)&PrivilegeFilter=0&page=\(page)") as? [String: Any]
    guard let code = json?["error_code"] as? Int, code == 0,
          let data = json?["data"] as? [String: Any] else { throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "酷狗搜索失败"]) }
    let lists = data["lists"] as? [[String: Any]] ?? []
    var seen = Set<String>()
    var out: [MusicInfo] = []
    for item in lists {
      let key = "\(item["Audioid"] ?? "")\(item["FileHash"] ?? "")"
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      if let m = map(item) { out.append(m) }
      for child in (item["Grp"] as? [[String: Any]] ?? []) {
        let ck = "\(child["Audioid"] ?? "")\(child["FileHash"] ?? "")"
        guard !seen.contains(ck) else { continue }
        seen.insert(ck)
        if let m = map(child) { out.append(m) }
      }
    }
    let total = (data["total"] as? Int) ?? out.count
    return (out, total)
  }

  private static func map(_ r: [String: Any]) -> MusicInfo? {
    guard let audioId = r["Audioid"] else { return nil }
    var quals: [MusicQualityType] = []
    if let n = r["FileSize"] as? Int, n != 0 { quals.append(.init(type: .q128k, size: iMusicSign.size(n))) }
    if let n = r["HQFileSize"] as? Int, n != 0 { quals.append(.init(type: .q320k, size: iMusicSign.size(n))) }
    if let n = r["SQFileSize"] as? Int, n != 0 { quals.append(.init(type: .flac, size: iMusicSign.size(n))) }
    if let n = r["ResFileSize"] as? Int, n != 0 { quals.append(.init(type: .flac24bit, size: iMusicSign.size(n))) }
    let singers = (r["Singers"] as? [[String: Any]]) ?? []
    let suffix = (r["Suffix"] as? String) ?? ""
    let secs = (r["Duration"] as? Int) ?? 0
    return MusicInfo(
      name: iMusicSign.decode("\(r["OriSongName"] ?? "")\(suffix.isEmpty ? "" : " \(suffix)")"),
      singer: iMusicSign.decode(iMusicSign.singerNames(singers)),
      source: .kg, songmid: "\(audioId)",
      albumName: iMusicSign.decode("\(r["AlbumName"] ?? "")"),
      interval: iMusicSign.mmss(secs),
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      extra: ["hash": "\(r["FileHash"] ?? "")", "albumAudioId": "\(r["MixSongID"] ?? "")",
              "albumId": "\(r["AlbumID"] ?? "")", "intervalSecs": "\(secs)"]
    )
  }
}

enum TxSearch {
  static func search(keyword: String, page: Int = 1, limit: Int = 30) async throws -> (items: [MusicInfo], total: Int) {
    var guid = ""
    for _ in 0..<32 { guid += String(format: "%x", Int.random(in: 0..<16)) }
    let searchId = guid.uppercased() + String(format: "%05d", Int.random(in: 0..<100000))
    let param: [String: Any] = ["grp": 1, "num_per_page": limit, "page_num": page, "query": keyword,
                                "remoteplace": "txt.newclient.top", "search_type": 0, "searchid": searchId]
    let searchSvc: [String: Any] = ["module": "music.search.SearchCgiService",
        "method": "DoSearchForQQMusicDesktop", "param": param]
    let comm: [String: Any] = ["_channelid": "0", "_os_version": "6.2.9200-2", "ct": "19", "cv": "2151",
        "guid": guid, "patch": "118", "psrf_access_token_expiresAt": 0,
        "psrf_qqaccess_token": "", "psrf_qqopenid": "", "psrf_qqunionid": "",
        "tmeAppID": "qqmusic", "tmeLoginType": 0, "uin": "0", "wid": "7223299733393904640"]
    let payloadStr = iMusicSign.txSignPayload(comm: comm, searchSvc: searchSvc, param: param)
    let sign = iMusicSign.zzcSign(payloadStr)
    let payload: [String: Any] = [
      "comm": ["_channelid": "0", "_os_version": "6.2.9200-2", "ct": "19", "cv": "2151",
               "guid": guid, "patch": "118", "psrf_access_token_expiresAt": 0,
               "psrf_qqaccess_token": "", "psrf_qqopenid": "", "psrf_qqunionid": "",
               "tmeAppID": "qqmusic", "tmeLoginType": 0, "uin": "0", "wid": "7223299733393904640"],
      "music.search.SearchCgiService": ["module": "music.search.SearchCgiService",
        "method": "DoSearchForQQMusicDesktop", "param": param],
    ]
    let json = try await iMusicHttp.postJSON("https://u.y.qq.com/cgi-bin/musics.fcg?sign=\(sign)", json: payload,
                                         headers: ["User-Agent": "QQMusic 14090508(android 12)"]) as? [String: Any]
    let svc = (json?["music.search.SearchCgiService"] ?? json?["req"]) as? [String: Any]
    let data = svc?["data"] as? [String: Any] ?? [:]
    let body = data["body"] as? [String: Any] ?? [:]
    let song = body["song"] as? [String: Any] ?? [:]
    let list = song["list"] as? [[String: Any]] ?? []
    let total = ((data["meta"] as? [String: Any])?["sum"] as? Int) ?? list.count
    return (list.compactMap(mapSong), total)
  }

  /// 单曲映射（搜索与 QQ 榜单共用，结构一致）
  static func mapSong(_ item: [String: Any]) -> MusicInfo? {
    guard let file = item["file"] as? [String: Any], let mediaMid = file["media_mid"] as? String else { return nil }
    var quals: [MusicQualityType] = []
    if let n = file["size_128mp3"] as? Int, n != 0 { quals.append(.init(type: .q128k, size: iMusicSign.size(n))) }
    if let n = file["size_320mp3"] as? Int, n != 0 { quals.append(.init(type: .q320k, size: iMusicSign.size(n))) }
    if let n = file["size_flac"] as? Int, n != 0 { quals.append(.init(type: .flac, size: iMusicSign.size(n))) }
    if let n = file["size_hires"] as? Int, n != 0 { quals.append(.init(type: .flac24bit, size: iMusicSign.size(n))) }
    let singers = (item["singer"] as? [[String: Any]]) ?? []
    let album = item["album"] as? [String: Any] ?? [:]
    let albumMid = (album["mid"] as? String) ?? ""
    let pic: String = {
      if albumMid.isEmpty || albumMid == "空" {
        guard let first = singers.first, let mid = first["mid"] as? String else { return "" }
        return "https://y.gtimg.cn/music/photo_new/T001R500x500M000\(mid).jpg"
      }
      return "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMid).jpg"
    }()
    let secs = (item["interval"] as? Int) ?? 0
    return MusicInfo(
      name: "\(item["title"] ?? "")",
      singer: iMusicSign.singerNames(singers),
      source: .tx, songmid: "\(item["mid"] ?? "")",
      albumName: "\(album["name"] ?? "")",
      interval: secs > 0 ? iMusicSign.mmss(secs) : nil,
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: pic.isEmpty ? nil : pic,
      extra: ["strMediaMid": mediaMid, "songId": "\(item["id"] ?? "")", "albumMid": albumMid]
    )
  }
}

enum WySearch {
  static func search(keyword: String, page: Int = 1, limit: Int = 30) async throws -> (items: [MusicInfo], total: Int) {
    let params = try iMusicSign.wyEapiParams(url: "/api/search/song/list/page", object: [
      "keyword": keyword, "needCorrect": "1", "channel": "typing",
      "offset": limit * (page - 1), "scene": "normal", "total": page == 1, "limit": limit,
    ])
    let json = try await iMusicHttp.postForm("http://interface.music.163.com/eapi/batch", form: ["params": params],
      headers: ["User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
                "origin": "https://music.163.com"]) as? [String: Any]
    guard let code = json?["code"] as? Int, code == 200,
          let data = json?["data"] as? [String: Any] else { throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "网易搜索失败"]) }
    let resources = data["resources"] as? [[String: Any]] ?? []
    let total = (data["totalCount"] as? Int) ?? resources.count
    return (resources.compactMap(map), total)
  }

  private static func map(_ w: [String: Any]) -> MusicInfo? {
    guard let item = (w["baseInfo"] as? [String: Any])?["simpleSongData"] as? [String: Any],
          let songId = item["id"] else { return nil }
    var quals: [MusicQualityType] = []
    let priv = item["privilege"] as? [String: Any] ?? [:]
    if (priv["maxBrLevel"] as? String) == "hires" {
      quals.append(.init(type: .flac24bit, size: iMusicSign.size((item["hr"] as? [String: Any])?["size"])))
    }
    switch (priv["maxbr"] as? Int) ?? 128000 {
    case 999000: quals.append(.init(type: .flac, size: iMusicSign.size((item["sq"] as? [String: Any])?["size"]))); fallthrough
    case 320000: quals.append(.init(type: .q320k, size: iMusicSign.size((item["h"] as? [String: Any])?["size"]))); fallthrough
    default: quals.append(.init(type: .q128k, size: iMusicSign.size((item["l"] as? [String: Any])?["size"])))
    }
    quals.reverse()
    let ar = (item["ar"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "、")
    let al = item["al"] as? [String: Any] ?? [:]
    let ms = (item["dt"] as? Int) ?? 0
    return MusicInfo(
      name: "\(item["name"] ?? "")", singer: ar,
      source: .wy, songmid: "\(songId)",
      albumName: "\(al["name"] ?? "")",
      interval: iMusicSign.mmss(ms / 1000),
      qualitys: quals,
      picUrl: al["picUrl"] as? String
    )
  }
}

enum MgSearch {
  static func search(keyword: String, page: Int = 1, limit: Int = 20) async throws -> (items: [MusicInfo], total: Int) {
    let time = "\(Int(Date().timeIntervalSince1970 * 1000))"
    let sig = iMusicSign.mgSign(time: time, keyword: keyword)
    let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
    let json = try await iMusicHttp.getJSON("https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch=%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D&pageSize=\(limit)&text=\(q)&pageNo=\(page)&sort=0&sid=USS",
      headers: ["uiVersion": "A_music_3.6.1", "deviceId": sig.deviceId, "timestamp": time, "sign": sig.sign,
                "channel": "0146921",
                "User-Agent": "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn) AppleWebKit/534.30 Version/4.0 Mobile Safari/534.30"]) as? [String: Any]
    guard (json?["code"] as? String) == "000000",
          let sr = json?["songResultData"] as? [String: Any] else {
      throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "咪咕搜索失败：\(json?["info"] ?? "")"])
    }
    let groups = sr["resultList"] as? [[[String: Any]]] ?? []
    var seen = Set<String>()
    var out: [MusicInfo] = []
    for g in groups {
      for d in g {
        guard let sid = d["songId"] as? String, let cid = d["copyrightId"] as? String, !seen.contains(cid) else { continue }
        seen.insert(cid)
        if let m = map(d, songId: sid, copyrightId: cid) { out.append(m) }
      }
    }
    let total = Int("\(sr["totalCount"] ?? 0)") ?? out.count
    return (out, total)
  }

  private static func map(_ d: [String: Any], songId: String, copyrightId: String) -> MusicInfo? {
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
    var img = (d["img3"] as? String) ?? (d["img2"] as? String) ?? (d["img1"] as? String) ?? ""
    if !img.isEmpty && !img.hasPrefix("http") { img = "http://d.musicapp.migu.cn" + img }
    let singers: String = {
      if let arr = d["singerList"] as? [[String: Any]] { return iMusicSign.singerNames(arr) }
      if let arr = d["singerList"] as? [String] { return arr.joined(separator: "、") }
      return "\(d["singer"] ?? "")"
    }()
    let secs = Int("\(d["duration"] ?? 0)") ?? 0
    return MusicInfo(
      name: "\(d["name"] ?? "")", singer: singers,
      source: .mg, songmid: songId,
      albumName: "\(d["album"] ?? "")",
      interval: iMusicSign.mmss(secs),
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: img.isEmpty ? nil : img,
      extra: ["copyrightId": copyrightId, "albumId": "\(d["albumId"] ?? "")",
              "lrcUrl": "\(d["lrcUrl"] ?? "")", "trcUrl": "\(d["trcUrl"] ?? "")"]
    )
  }
}
