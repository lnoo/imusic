import Foundation

// MARK: - QQ音乐解析（AnyListenTx）
//
// 解析逻辑对齐 extensions/online-metadata/src/onlineResource/tx/ 下
//   {musicSearch,topSongs,songlist,lyric,pic}.ts（端点已逐个实测）：
//   musicSearch   [musicSearch.ts] musicu.fcg DoSearchForQQMusicMobile（扩展走签名
//                 musics.fcg DoSearchForQQMusicDesktop + zzcSign；此处保留免签名同类响应）
//   topSongs      [topSongs.ts] musicu.fcg musicToplist.ToplistInfoServer GetAll（榜单目录，带榜图）
//                 + GetDetail（topid；info.desc 取 detail.intro）
//   歌单          [songlist.ts] GetAllTag（标签）+ fcg_get_diss_by_tag（按分类/排序浏览）
//                 + client_music_search_songlist（歌单搜索）+ fcg_ucc_getcdinfo_byids_cp
//                 （详情首选，subcode != 0 回落 srf_diss_info.DissInfoServer.CgiGetDiss POST）
//   热搜/提示     [hotSearch.ts] musicu.fcg HotkeyService.GetHotkeyForQQMusicPC
//                 [tipSearch.ts] splcloud/fcgi-bin/smartbox_new.fcg
//   lyric         [lyric.ts] GetPlayLyricInfo（qrc/trans/roma）+ QRC 三重DES解码（LyricCodec.decodeQRC）
//   pic           [pic.ts] albumMid → y.gtimg.cn T002R500x500M000 公式直链
//   url 兜底      GD音乐台 types=url&source=tencent（iMusic 特有的直链兜底，扩展无此动作；
//                 与 any-listen GD音乐台扩展同源）

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
          let data = req["data"] as? [String: Any],
          let body = data["body"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("QQ音乐搜索失败")
    }
    let songs = body["item_song"] as? [[String: Any]] ?? []
    let list = ALNormalize.dedup(songs.compactMap(mapSong)) { $0.songmid }
    // 扩展用 meta.sum 作精确总数；无该字段时按“取满一页即视为还有下一页”估算（供 UI 翻页判断）
    let sum = (data["meta"] as? [String: Any]).flatMap { ALHttp.int($0["sum"]) }
    let total = sum ?? (list.count >= limit ? page * limit + 1 : (page - 1) * limit + list.count)
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  /// tx 歌曲条目 → MusicInfo（搜索/榜单/歌单详情共用；含 media_mid 与封面公式）
  static func mapSong(_ item: [String: Any]) -> MusicInfo? {
    guard let mid = item["mid"] as? String else { return nil }
    let file = item["file"] as? [String: Any] ?? [:]
    var quals: [MusicQualityType] = []
    if let n = ALHttp.int(file["size_128mp3"]), n != 0 { quals.append(.init(type: .q128k, size: ALFormat.sizeFormate(n))) }
    if let n = ALHttp.int(file["size_320mp3"]), n != 0 { quals.append(.init(type: .q320k, size: ALFormat.sizeFormate(n))) }
    if let n = ALHttp.int(file["size_flac"]), n != 0 { quals.append(.init(type: .flac, size: ALFormat.sizeFormate(n))) }
    if let n = ALHttp.int(file["size_hires"]), n != 0 { quals.append(.init(type: .flac24bit, size: ALFormat.sizeFormate(n))) }
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
    let intervalRaw = item["interval"]
    let secs = ALHttp.int(intervalRaw) ?? 0
    // 歌名：name 为干净本体，title = <em>高亮本体</em> + title_extra 版本后缀（如
    // " (Single Version)"）→ 用 name + title_extra 组装，避免 <em> 进搜索/播放页；
    // name 缺失才回退 title（decode 已剥 <em>）
    let baseName = ALHttp.str(item["name"])
    let rawName = baseName.isEmpty
      ? ALHttp.str(item["title"] ?? item["name"])
      : baseName + ALHttp.str(item["title_extra"])
    return MusicInfo(
      name: iMusicSign.decode(rawName),
      singer: ALFormat.singerName(singers),
      source: .tx, songmid: mid,
      albumName: ALFormat.decodeName(ALHttp.str(album["name"])),
      // interval 缺失 → nil；为 0 → ALFormat.playTime 的 "--/--"（与扩展 formatPlayTime 一致）
      interval: intervalRaw == nil ? nil : ALFormat.playTime(secs),
      qualitys: quals,
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

  /// 榜单期次抓取（对齐 extensions/.../tx/topSongs.ts 的 periodUrl / regExps / getPeriods）
  private static let periodUrl = "https://c.y.qq.com/node/pc/wk_v15/top.html"
  /// 对应 regExps.periodList（JS 的 `\/` 在 ICU 正则中直接写作 `/`）
  private static let periodListPattern = #"<i class="play_cover__btn c_tx_link js_icon_play" data-listkey=".+?" data-listname=".+?" data-tid=".+?" data-date=".+?" .+?</i>"#
  /// 对应 regExps.period：1=name 2=bangid 3=period
  private static let periodPattern = #"data-listname="(.+?)" data-tid=".*?/(.+?)" data-date="(.+?)" .+?</i>"#
  private static let periodListRegex = try? NSRegularExpression(pattern: periodListPattern)
  private static let periodRegex = try? NSRegularExpression(pattern: periodPattern)

  private struct PeriodInfo: Sendable {
    let name: String
    let bangid: String
    let period: String
  }

  /// NSLock 守护可变字典，容器以 static let + @unchecked Sendable 暴露，满足 Swift 6 严格并发
  private final class PeriodInfoCache: @unchecked Sendable {
    private let lock = NSLock()
    private var infos: [String: PeriodInfo] = [:]

    func period(for bangid: String) -> String? {
      lock.lock(); defer { lock.unlock() }
      return infos[bangid]?.period
    }

    func store(_ info: PeriodInfo) {
      lock.lock(); defer { lock.unlock() }
      infos[info.bangid] = info
    }
  }
  private static let periodCache = PeriodInfoCache()

  /// 对齐扩展 getPeriods：GET 榜单目录 HTML → 抓取全部期次条目入缓存 → 返回 bangid 对应 period
  private static func getPeriods(bangid: String) async -> String? {
    guard let data = try? await ALHttp.getRaw(periodUrl).data else { return nil }
    let html: String = {
      if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
      let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
      return String(data: data, encoding: gbk) ?? String(decoding: data, as: UTF8.self)
    }()
    guard let listRegex = periodListRegex, let itemRegex = periodRegex else { return nil }
    let items = listRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
    guard !items.isEmpty else { return nil }
    for item in items {
      guard let itemRange = Range(item.range, in: html) else { continue }
      let fragment = String(html[itemRange])
      guard let match = itemRegex.firstMatch(in: fragment,
              range: NSRange(fragment.startIndex..., in: fragment)),
            match.numberOfRanges >= 4,
            let nameRange = Range(match.range(at: 1), in: fragment),
            let bangidRange = Range(match.range(at: 2), in: fragment),
            let periodRange = Range(match.range(at: 3), in: fragment) else { continue }
      periodCache.store(PeriodInfo(name: String(fragment[nameRange]),
                                   bangid: String(fragment[bangidRange]),
                                   period: String(fragment[periodRange])))
    }
    return periodCache.period(for: bangid)
  }

  static func topSongsDetail(id: String, date: String? = nil, page: Int, limit: Int) async throws -> ALTopSongsDetailResult {
    let topid = Int(id) ?? 26
    // 对齐扩展 getList 的 period 解析顺序：指定 date → 缓存期次 → 实时抓取期次
    var period: String?
    if let date, !date.isEmpty {
      period = date
    } else if let cached = periodCache.period(for: id) {
      period = cached
    } else {
      period = await getPeriods(bangid: id)
    }
    var detailParam: [String: Any] = ["topid": topid, "num": limit, "offset": (page - 1) * limit]
    if let period { detailParam["period"] = period }
    let payload: [String: Any] = [
      "comm": ["uin": 0, "format": "json", "ct": 20, "cv": 1859],
      "toplist": ["module": "musicToplist.ToplistInfoServer", "method": "GetDetail",
                  "param": detailParam],
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
    // 对齐 topSongs.ts：info.desc 取 detail.intro（非 titleDetail），解码并把 <br> 转成换行
    let intro = ALFormat.decodeName(ALHttp.str(meta["intro"]))
      .replacingOccurrences(of: "<br />", with: "\n")
      .replacingOccurrences(of: "<br/>", with: "\n")
      .replacingOccurrences(of: "<br>", with: "\n")
    return ALTopSongsDetailResult(
      list: list, total: list.count, page: page, limit: limit,
      info: ALTopSongsDetailInfo(name: ALFormat.decodeName(ALHttp.str(meta["title"])),
                                 pic: ALHttp.str(meta["frontPicUrl"]).isEmpty ? nil : ALHttp.str(meta["frontPicUrl"]),
                                 desc: intro,
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
    // 对齐 songlist.ts sortList：recommend=-1 / hot=3 / new=2
    [ALTagItem(id: "-1", name: "推荐"), ALTagItem(id: "3", name: "最热"), ALTagItem(id: "2", name: "最新")]
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
    // 对齐 songlist.ts：优先 content.total_cnt / total_cnt，缺失则沿用响应的 sum
    let content = data["content"] as? [String: Any]
    let total = ALHttp.int(content?["total_cnt"]) ?? ALHttp.int(data["total_cnt"])
      ?? ALHttp.int(data["sum"]) ?? diss.count
    let list = diss.map { d in
      let rawDesc = ALHttp.str(d["desc"])
      let desc = ALFormat.decodeName(rawDesc.isEmpty ? ALHttp.str(d["introduction"]) : rawDesc)
        .replacingOccurrences(of: "<br>", with: "\n")
      return ALSongListItem(id: ALHttp.str(d["dissid"]), name: ALHttp.str(d["dissname"]),
                            playCount: ALFormat.playCount(d["listennum"]),
                            author: (d["creator"] as? [String: Any]).map { ALHttp.str($0["name"]) },
                            img: d["imgurl"] as? String,
                            desc: desc.isEmpty ? nil : desc,
                            total: ALHttp.int(d["total_cnt"]) ?? ALHttp.int(d["song_count"]))
    }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  /// 对齐 songlist.ts search：`client_music_search_songlist` GET（此前误用分类浏览假实现）
  static func songlistSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    let url = "http://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist?page_no=\(page - 1)&num_per_page=\(limit)&format=json&query=\(uriComponent(keyword))&remoteplace=txt.yqq.playlist&inCharset=utf8&outCharset=utf-8"
    let json = try await ALHttp.getJSON(url,
      headers: ["Referer": "http://y.qq.com/portal/search.html", "User-Agent": UA],
      requireOK: true) as? [String: Any]
    guard let root = json, ALHttp.int(root["code"]) == 0,
          let data = root["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("QQ歌单搜索失败")
    }
    let rawList = data["list"] as? [[String: Any]] ?? []
    let list = rawList.map { d -> ALSongListItem in
      let creator = d["creator"] as? [String: Any]
      // 扩展对 introduction 做两次 decodeName（实体可能嵌套），再把 <br> 还原为换行
      let intro = decodeText(ALFormat.decodeName(ALHttp.str(d["introduction"])))
      return ALSongListItem(
        id: ALHttp.str(d["dissid"]),
        name: decodeText(ALHttp.str(d["dissname"])),
        playCount: ALFormat.playCount(d["listennum"]),
        author: creator.map { decodeText(ALHttp.str($0["name"])) },
        time: formatYMD(d["createtime"]),
        img: d["imgurl"] as? String,
        desc: intro.isEmpty ? nil : intro,
        total: ALHttp.int(d["song_count"]))
    }
    return ALListResult(list: list, total: ALHttp.int(data["sum"]) ?? list.count, page: page, limit: limit)
  }

  /// 对齐 songlist.ts getListDetail：先走 cdinfo GET，subcode != 0 / 异常时回落原有 POST 详情
  static func songlistDetail(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    let q = ALHttp.query([("type", "1"), ("json", "1"), ("utf8", "1"), ("onlysong", "0"),
                          ("new_format", "1"), ("disstid", id), ("loginUin", "0"), ("hostUin", "0"),
                          ("format", "json"), ("inCharset", "utf8"), ("outCharset", "utf-8"),
                          ("notice", "0"), ("platform", "yqq.json"), ("needNewCode", "0")])
    let url = "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?\(q)"
    let headers = ["Origin": "https://y.qq.com",
                   "Referer": "https://y.qq.com/n/yqq/playsquare/\(id).html",
                   "User-Agent": UA]
    if let json = try? await ALHttp.getJSON(url, headers: headers) as? [String: Any],
       ALHttp.int(json["code"]) == 0,
       ALHttp.int(json["subcode"]) == 0,
       let cdlist = json["cdlist"] as? [[String: Any]],
       let cd = cdlist.first {
      // 与扩展 buildMusicList 一致：无 file.media_mid 的条目不可播，直接剔除
      let songs = (cd["songlist"] as? [[String: Any]] ?? []).filter {
        !ALHttp.str(($0["file"] as? [String: Any])?["media_mid"]).isEmpty
      }
      let list = songs.compactMap(mapSong)
      let name = decodeText(ALHttp.str(cd["dissname"]))
      let img = ALHttp.str(cd["logo"])
      let desc = decodeText(ALHttp.str(cd["desc"]))
      let author = decodeText(ALHttp.str(cd["nickname"]))
      let info = ALSongListDetailInfo(
        name: name,
        img: img.isEmpty ? nil : img,
        desc: desc.isEmpty ? nil : desc,
        author: author.isEmpty ? nil : author,
        playCount: ALFormat.playCount(cd["visitnum"]),
        date: nil)
      let total = ALHttp.int(cd["songnum"]) ?? ALHttp.int(cd["total_song_num"]) ?? list.count
      return ALSonglistDetailResult(list: list, total: total, page: page, limit: limit, info: info)
    }
    return try await songlistDetailViaDissInfo(id: id, page: page, limit: limit)
  }

  /// 原有 POST 详情路径（扩展对应 aiDissInfo.uniform_get_Dissinfo；本文件沿用同类
  /// srf_diss_info.DissInfoServer.CgiGetDiss，行为保持不变），作为首选端点的兜底
  private static func songlistDetailViaDissInfo(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
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
      playCount: ALFormat.playCount(dirinfo["listennum"]),
      date: nil)
    return ALSonglistDetailResult(list: list, total: total, page: page, limit: limit, info: info)
  }

  // MARK: 热搜 / 搜索提示（tx/hotSearch.ts、tx/tipSearch.ts）

  static func hotSearch() async throws -> [String] {
    let payload: [String: Any] = [
      "comm": ["ct": "19", "cv": "1803", "guid": "0", "patch": "118",
               "psrf_access_token_expiresAt": 0, "psrf_qqaccess_token": "",
               "psrf_qqopenid": "", "psrf_qqunionid": "", "tmeAppID": "qqmusic",
               "tmeLoginType": 0, "uin": "0", "wid": "0"],
      "hotkey": ["method": "GetHotkeyForQQMusicPC",
                 "module": "tencent_musicsoso_hotkey.HotkeyService",
                 "param": ["search_id": "", "uin": 0]],
    ]
    let json = try await ALHttp.postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload,
      headers: ["Referer": "https://y.qq.com/portal/player.html"]) as? [String: Any]
    guard let root = json, ALHttp.int(root["code"]) == 0 else {
      throw ALSourceError.invalidResponse("QQ热搜失败")
    }
    let data = (root["hotkey"] as? [String: Any])?["data"] as? [String: Any]
    return (data?["vec_hotkey"] as? [[String: Any]] ?? [])
      .map { ALHttp.str($0["query"]) }
      .filter { !$0.isEmpty }
  }

  static func tipSearch(keyword: String) async throws -> [String] {
    let url = "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?is_xml=0&format=json&key=\(uriComponent(keyword))&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq&needNewCode=0"
    let json = try await ALHttp.getJSON(url,
      headers: ["Referer": "https://y.qq.com/portal/player.html"],
      requireOK: true) as? [String: Any]
    guard let root = json, ALHttp.int(root["code"]) == 0 else {
      throw ALSourceError.invalidResponse("QQ搜索提示失败")
    }
    let song = (root["data"] as? [String: Any])?["song"] as? [String: Any]
    return (song?["itemlist"] as? [[String: Any]] ?? []).map { item in
      "\(ALHttp.str(item["name"])) \(ALHttp.str(item["singer"]))"
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  // MARK: 私有格式化助手

  /// JS encodeURIComponent 等价字符集（保留 A-Za-z0-9 与 -_.!~*'()）
  private static func uriComponent(_ text: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.!~*'()")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }

  /// decodeName + `<br>` 还原换行（对齐扩展 .replace(/<br>/g, '\\n')）
  private static func decodeText(_ value: String?) -> String {
    ALFormat.decodeName(value)
      .replacingOccurrences(of: "<br />", with: "\n")
      .replacingOccurrences(of: "<br/>", with: "\n")
      .replacingOccurrences(of: "<br>", with: "\n")
  }

  /// dateFormat(_, 'Y-M-D')：兼容日期字符串与秒/毫秒时间戳
  private static func formatYMD(_ value: Any?) -> String? {
    let raw = ALHttp.str(value).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    var date: Date?
    for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yyyy/MM/dd"] {
      parser.dateFormat = fmt
      if let parsed = parser.date(from: raw) { date = parsed; break }
    }
    if date == nil, let n = ALHttp.double(value) {
      date = Date(timeIntervalSince1970: (n > 1e12 ? n : n * 1000) / 1000)
    }
    guard let date else {
      let prefix = String(raw.prefix(10))
      return prefix.count == 10 ? prefix : nil
    }
    let out = DateFormatter()
    out.locale = Locale(identifier: "en_US_POSIX")
    out.dateFormat = "yyyy-MM-dd"
    return out.string(from: date)
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
