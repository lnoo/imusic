import Foundation

// MARK: - 酷狗解析（AnyListenKg）
//
// 严格对齐 extensions/online-metadata/src/onlineResource/kg/ 下的 TS 实现（只读参考）：
//   musicSearch.ts      songsearch.kugou.com/song_search_v2（WebFilter 参数串；Audioid+FileHash
//                       去重；128k/320k/flac/flac24bit 四档各自 size + hash）
//   topSongs.ts         rank/list（isvol 榜单 + 榜图/简介）+ rank/song 榜单详情
//                       （详情每档须 size>0 且有 hash 才声明音质）
//   songlist.ts         getSpecial 标签/排序/列表浏览（含 everydayrec 推荐）；search/special 歌单搜索
//   songlistDetail.ts   special/single HTML 解析 + t.kugou.com/command 分享码 + gcid 签名链
//                       （chain/gcid_/schain/zlist/redirect 等全部分支）
//   musicDetail.ts      gateway.kugou.com/v2/album_audio/audio（100/批 + 逐档 hash/size）
//   hotSearch.ts        hot_tab 热搜词；tipSearch.ts getSearchTip 联想词
//   lyric.ts            lyrics.kugou.com search + download；timelength 单位为「秒」；
//                       仅取 candidates[0]；按响应 body.fmt 分支（krc 逐字 / lrc 明文）
//   pic.ts              搜索结果自带 Image（{size} → 400）；独立 res_privilege 封面端点
//                       Swift 侧暂未移植
//   url                 kg 扩展未声明 musicUrl 动作；Swift 侧降级返回 nil

enum AnyListenKg {
  // MARK: - 工具

  /// 对标 TS `encodeURIComponent`：字母数字 + `-_.!~*'()` 不转义，其余百分号编码。
  private static func encodeURIComponent(_ s: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
  }

  /// 对标 lyric.ts `getIntv`：mm:ss（可含 hh:mm:ss）→ 秒；无 meta._interval 时兜底用。
  private static func intv(from interval: String?) -> Int {
    guard let interval, !interval.isEmpty else { return 0 }
    var total = 0
    var unit = 1
    for part in interval.split(separator: ":").reversed() {
      total += (Int(part) ?? 0) * unit
      unit *= 60
    }
    return total
  }

  // MARK: 搜索（song_search_v2）

  static func musicSearch(keyword: String, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    let q = encodeURIComponent(keyword)
    let json = try await ALHttp.getJSON(
      "https://songsearch.kugou.com/song_search_v2?keyword=\(q)&page=\(page)&pagesize=\(limit)&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1") as? [String: Any]
    guard let data = json?["data"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("酷狗搜索失败")
    }
    let lists = data["lists"] as? [[String: Any]] ?? []
    var out: [MusicInfo] = []
    var seen = Set<String>()
    for item in lists {
      // 扩展按 Audioid + FileHash 拼接去重（不是仅 Audioid）
      let key = ALHttp.str(item["Audioid"]) + ALHttp.str(item["FileHash"])
      guard seen.insert(key).inserted, let m = mapSearchItem(item) else { continue }
      out.append(m)
      for child in item["Grp"] as? [[String: Any]] ?? [] {
        let ck = ALHttp.str(child["Audioid"]) + ALHttp.str(child["FileHash"])
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
    let fileHash = ALHttp.str(r["FileHash"])
    let hqHash = ALHttp.str(r["HQFileHash"])
    let sqHash = ALHttp.str(r["SQFileHash"])
    let resHash = ALHttp.str(r["ResFileHash"])
    var quals: [MusicQualityType] = []
    if let n = ALHttp.int(r["FileSize"]), n != 0 { quals.append(.init(type: .q128k, size: ALFormat.sizeFormate(n))) }
    if let n = ALHttp.int(r["HQFileSize"]), n != 0 { quals.append(.init(type: .q320k, size: ALFormat.sizeFormate(n))) }
    if let n = ALHttp.int(r["SQFileSize"]), n != 0 { quals.append(.init(type: .flac, size: ALFormat.sizeFormate(n))) }
    if let n = ALHttp.int(r["ResFileSize"]), n != 0 { quals.append(.init(type: .flac24bit, size: ALFormat.sizeFormate(n))) }
    let suffix = ALHttp.str(r["Suffix"])
    let secs = ALHttp.int(r["Duration"]) ?? 0
    let pic = Self.expandSize(ALHttp.str(r["Image"]), size: "400")
    // 扩展不为「无档位」条目伪造 128k；qualitys 为空时即空数组
    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(r["OriSongName"]) + (suffix.isEmpty ? "" : " \(suffix)")),
      singer: ALFormat.singerName(r["Singers"]),
      source: .kg, songmid: "\(audioId)",
      albumName: ALFormat.decodeName(ALHttp.str(r["AlbumName"])),
      interval: ALFormat.playTime(secs),
      qualitys: quals,
      picUrl: pic.isEmpty ? nil : pic,
      extra: ["hash": fileHash, "hqHash": hqHash, "sqHash": sqHash, "resHash": resHash,
              "albumAudioId": ALHttp.str(r["MixSongID"]),
              "albumId": ALHttp.str(r["AlbumID"]), "intervalSecs": "\(secs)"]
    )
  }

  /// kg 图链 {size} 占位 → 具体尺寸（150/240/400/500）
  static func expandSize(_ url: String, size: String = "400") -> String {
    url.replacingOccurrences(of: "{size}", with: size)
  }

  // MARK: 榜单（rank/list：56 张榜带图；rank/song：榜单详情）

  /// 对标 topSongs.ts boardInfoMap（榜目录 intro → desc）。保持既有 v3 榜目录与 240 图链不变，
  /// 只补齐元数据中的 desc，供榜单详情复用（静态 boardList 的 desc 全为空，无需复制）。
  private struct KGBoardInfo: Sendable {
    var name: String
    var pic: String?
    var desc: String?
  }

  private static func fetchBoards() async -> (items: [ALTopSongsItem], infos: [String: KGBoardInfo]) {
    guard let json = try? await ALHttp.getJSON(
      "http://mobilecdnbj.kugou.com/api/v3/rank/list?version=9108&ranktype=1&plat=0&pagesize=100&page=1&area_code=1") as? [String: Any],
          let data = ALHttp.dict(json["data"]) else { return ([], [:]) }
    var items: [ALTopSongsItem] = []
    var infos: [String: KGBoardInfo] = [:]
    for g in ALHttp.arr(data["info"]) ?? [] {
      let id = ALHttp.str(g["rankid"])
      let name = ALHttp.str(g["rankname"])
      guard !id.isEmpty, !name.isEmpty else { continue }
      let raw = ALHttp.str(g["img_9"])
      let pic = expandSize(raw.isEmpty ? ALHttp.str(g["banner_9"]) : raw, size: "240")
      let finalPic = pic.isEmpty ? nil : pic
      items.append(ALTopSongsItem(id: id, name: name, pic: finalPic))
      let intro = ALFormat.decodeName(ALHttp.str(g["intro"]))
      infos[id] = KGBoardInfo(name: name, pic: finalPic, desc: intro.isEmpty ? nil : intro)
    }
    return (items, infos)
  }

  static func topSongs() async -> [ALTopSongsItem] { await fetchBoards().items }

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
    let rawInfo = ALHttp.arr(data["info"]) ?? []
    let list = rawInfo.compactMap(mapRankSong)
    // boardInfoMap：名称/图/简介一次取自榜目录（intro 即 desc），不再只回填 name/pic
    let boardInfo = await fetchBoards().infos[id]
    var info = ALTopSongsDetailInfo(
      name: boardInfo?.name ?? "排行榜详情",
      pic: boardInfo?.pic,
      desc: boardInfo?.desc,
      date: nil)
    // 详情响应若自带 desc/intro，则优先采用（对齐扩展「有 desc 就填」的语义）
    let detailDesc = [ALHttp.str(data["desc"]), ALHttp.str(json?["desc"]), ALHttp.str(data["intro"])]
      .first { !$0.isEmpty }
    if let detailDesc { info.desc = ALFormat.decodeName(detailDesc) }
    if let rawDate = rawInfo.first.map({ ALHttp.str($0["rank_id_publish_date"]) }), rawDate.count >= 10 {
      info.date = String(rawDate.prefix(10))
    }
    let total = ALHttp.int(data["total"]) ?? list.count
    return ALTopSongsDetailResult(list: list, total: total, page: page, limit: limit, info: info)
  }

  /// rank/song 条目（authors/songname/filesize 320filesize sqfilesize filesize_high）
  /// 对齐 topSongs.ts createQuality：size>0 且对应 hash 非空才声明该档，并保留逐档 hash。
  private static func mapRankSong(_ r: [String: Any]) -> MusicInfo? {
    guard let audioId = ALHttp.int(r["audio_id"]) else { return nil }
    let hash = ALHttp.str(r["hash"])
    let hqHash = ALHttp.str(r["320hash"])
    let sqHash = ALHttp.str(r["sqhash"])
    let resHash = ALHttp.str(r["hash_high"])
    var quals: [MusicQualityType] = []
    if let n = ALHttp.int(r["filesize"]), n > 0, !hash.isEmpty { quals.append(.init(type: .q128k, size: ALFormat.sizeFormate(n))) }
    if let n = ALHttp.int(r["320filesize"]), n > 0, !hqHash.isEmpty { quals.append(.init(type: .q320k, size: ALFormat.sizeFormate(n))) }
    if let n = ALHttp.int(r["sqfilesize"]), n > 0, !sqHash.isEmpty { quals.append(.init(type: .flac, size: ALFormat.sizeFormate(n))) }
    if let n = ALHttp.int(r["filesize_high"]), n > 0, !resHash.isEmpty { quals.append(.init(type: .flac24bit, size: ALFormat.sizeFormate(n))) }
    let authors = ALFormat.singerName(r["authors"], key: "author_name")
    let secs = ALHttp.int(r["duration"]) ?? 0
    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(r["songname"])),
      singer: authors,
      source: .kg, songmid: "\(audioId)",
      albumName: ALFormat.decodeName(ALHttp.str(r["remark"])),
      interval: ALFormat.playTime(secs),
      qualitys: quals.isEmpty ? [.init(type: .q128k, size: nil)] : quals,
      picUrl: expandSize(ALHttp.str(r["image"])).isEmpty ? nil : expandSize(ALHttp.str(r["image"])),
      extra: ["hash": hash, "hqHash": hqHash, "sqHash": sqHash, "resHash": resHash,
              "albumAudioId": ALHttp.str(r["album_audio_id"]),
              "albumId": ALHttp.str(r["album_id"]), "intervalSecs": "\(secs)"]
    )
  }

  // MARK: - 歌单（songlist.ts / songlistDetail.ts / musicDetail.ts）

  private static let limitSong = 10000 // songlistDetail.ts pageInfo.limitSong

  /// songlist.ts getInfoUrl：标签/列表元信息端点（无标签与带标签两种形态）
  private static let specialInfoURL = "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_smarty=1&"

  /// songlist.ts pageInfo.sortList（扩展返回 i18n key，Swift 侧用中文显示名）
  static func songlistSorts() async -> [ALTagItem] {
    [
      ALTagItem(id: "5", name: "推荐"),
      ALTagItem(id: "6", name: "最热"),
      ALTagItem(id: "7", name: "最新"),
      ALTagItem(id: "3", name: "热藏"),
      ALTagItem(id: "8", name: "飙升"),
    ]
  }

  /// songlist.ts getTags → filterTagInfo（分组标签）+ filterInfoHotTag（热门标签）
  static func songlistTags() async -> ALSonglistTagResult {
    guard let json = try? await ALHttp.getJSON(specialInfoURL) as? [String: Any],
          ALHttp.int(json["status"]) == 1,
          let data = ALHttp.dict(json["data"]) else {
      return ALSonglistTagResult(tags: [], hotTags: [])
    }
    var hotTags: [ALTagItem] = []
    if let hot = ALHttp.dict(data["hotTag"]), ALHttp.int(hot["status"]) == 1 {
      // TS 按 Object.keys 插入序；Swift 字典无序 → 按 sort + id 稳定排序
      let rawTags = (ALHttp.dict(hot["data"]) ?? [:]).values.compactMap { ALHttp.dict($0) }.sorted { a, b in
        let sa = ALHttp.int(a["sort"]) ?? 0, sb = ALHttp.int(b["sort"]) ?? 0
        if sa != sb { return sa < sb }
        return ALHttp.str(a["special_id"]) < ALHttp.str(b["special_id"])
      }
      hotTags = rawTags.compactMap { tag in
        let id = ALHttp.str(tag["special_id"])
        let name = ALFormat.decodeName(ALHttp.str(tag["special_name"]))
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return ALTagItem(id: id, name: name)
      }
    }
    var groups: [ALTagGroupItem] = []
    let tagids = ALHttp.dict(data["tagids"]) ?? [:]
    for (groupName, rawGroup) in tagids.sorted(by: { $0.key < $1.key }) {
      let list = (ALHttp.arr(ALHttp.dict(rawGroup)?["data"]) ?? []).compactMap { tag -> ALTagItem? in
        let id = ALHttp.str(tag["id"])
        let name = ALFormat.decodeName(ALHttp.str(tag["name"]))
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return ALTagItem(id: id, name: name)
      }
      if !list.isEmpty { groups.append(ALTagGroupItem(name: ALFormat.decodeName(groupName), list: list)) }
    }
    return ALSonglistTagResult(tags: groups, hotTags: hotTags)
  }

  /// songlist.ts getListInfo：data.params.total / data.params.pagesize
  private static func getListInfo(tag: String) async throws -> (total: Int, limit: Int) {
    let url = tag.isEmpty
      ? specialInfoURL
      : "\(specialInfoURL)cdn=cdn&t=5&c=\(encodeURIComponent(tag))"
    let json = try await ALHttp.getJSON(url) as? [String: Any]
    guard ALHttp.int(json?["status"]) == 1,
          let params = ALHttp.dict(ALHttp.dict(json?["data"])?["params"]) else {
      throw ALSourceError.invalidResponse("酷狗歌单列表信息失败")
    }
    return (ALHttp.int(params["total"]) ?? 0, ALHttp.int(params["pagesize"]) ?? 0)
  }

  /// songlist.ts getSongListRecommend：无标签 + 推荐 + 首页时插到列表最前
  private static func songlistRecommend() async throws -> [ALSongListItem] {
    let body: [String: Any] = [
      "appid": 1001, "clienttime": 1566798337219, "clientver": 8275,
      "key": "f1f93580115bb106680d2375f8032d96",
      "mid": "21511157a05844bd085308bc76ef3343", "platform": "pc",
      "userid": "262643156", "return_min": 6, "return_max": 15,
    ]
    let json = try await ALHttp.postJSON(
      "http://everydayrec.service.kugou.com/guess_special_recommend",
      json: body,
      headers: ["User-Agent": "KuGou2012-8275-web_browser_event_handler"]) as? [String: Any]
    guard let root = json, ALHttp.int(root["status"]) == 1,
          let list = ALHttp.arr(ALHttp.dict(root["data"])?["special_list"]) else {
      throw ALSourceError.invalidResponse("酷狗推荐歌单失败")
    }
    return list.compactMap(mapSonglistBrowseItem)
  }

  /// songlist.ts filterList：兼容 special_db（total_play_count/publish_time/img/song_count）
  /// 与 recommend/search（play_count/publishtime/imgurl/songcount）两种条目形状。
  private static func mapSonglistBrowseItem(_ s: [String: Any]) -> ALSongListItem? {
    let rawId = ALHttp.str(s["specialid"])
    let name = ALFormat.decodeName(ALHttp.str(s["specialname"]))
    guard !rawId.isEmpty, !name.isEmpty else { return nil }
    let playCount: String = {
      if let total = s["total_play_count"] as? String, !total.isEmpty { return total }
      return ALFormat.playCount(ALHttp.int(s["play_count"]) ?? 0)
    }()
    let publish = ALHttp.str(s["publish_time"])
    let timeRaw = publish.isEmpty ? ALHttp.str(s["publishtime"]) : publish
    let rawImg = ALHttp.str(s["img"])
    let img = expandSize(rawImg.isEmpty ? ALHttp.str(s["imgurl"]) : rawImg)
    let intro = ALFormat.decodeName(ALHttp.str(s["intro"]))
    return ALSongListItem(
      id: "id_\(rawId)", name: name, playCount: playCount,
      author: (s["nickname"] as? String).map { ALFormat.decodeName($0) },
      time: Self.dateOnly(timeRaw),
      img: img.isEmpty ? nil : img,
      desc: intro.isEmpty ? nil : intro,
      total: ALHttp.int(s["song_count"]) ?? ALHttp.int(s["songcount"]))
  }

  private static func dateOnly(_ raw: String) -> String? {
    guard !raw.isEmpty else { return nil }
    return raw.count >= 10 ? String(raw.prefix(10)) : raw
  }

  /// songlist.ts getList：getSpecial?is_ajax=1&cdn=cdn&t=<sort>&c=<tag>&p=<page>
  static func songlist(sort: String, tag: String, page: Int, limit: Int) async throws -> ALListResult<ALSongListItem> {
    let sortId = sort.isEmpty ? "5" : sort
    let url = "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn&t=\(sortId)&c=\(tag)&p=\(page)"
    let json = try await ALHttp.getJSON(url) as? [String: Any]
    guard ALHttp.int(json?["status"]) == 1 else {
      throw ALSourceError.invalidResponse("酷狗歌单列表失败")
    }
    var list = (ALHttp.arr(json?["special_db"]) ?? []).compactMap(mapSonglistBrowseItem)
    if tag.isEmpty, page == 1, sortId == "5" {
      // 推荐接口不属于主链，失败时保持原列表可用
      if let recommended = try? await songlistRecommend() {
        list.insert(contentsOf: recommended, at: 0)
      }
    }
    let info = try await getListInfo(tag: tag)
    return ALListResult(list: ALNormalize.dedup(list, id: { $0.id }),
                        total: info.total, page: page,
                        limit: info.limit > 0 ? info.limit : limit)
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
      // 与 songlist.ts filterList 一致用 id_ 前缀；详情入口据此走 special/single 链
      ALSongListItem(id: "id_\(ALHttp.str(s["specialid"]))", name: ALHttp.str(s["specialname"]),
                     playCount: ALNormalize.playCount(s["playcount"]),
                     author: s["nickname"] as? String,
                     img: expandSize(ALHttp.str(s["img"])).isEmpty ? nil : expandSize(ALHttp.str(s["img"])),
                     desc: s["intro"] as? String,
                     total: ALHttp.int(s["songcount"]))
    }
    return ALListResult(list: list, total: total, page: page, limit: limit)
  }

  /// songlistDetail.ts getListDetail 的分发（:572-607）：
  /// special/single/ → detailLink 数字 id；id_ → specialId；纯数字 → 分享码链；
  /// http(s) → 详情数字链接走 specialId，其余链接走 getUserListDetail 级联。
  static func songlistDetail(id: String, page: Int, limit: Int) async throws -> ALSonglistDetailResult {
    var rawId = id.trimmingCharacters(in: .whitespacesAndNewlines)
    if let hash = rawId.firstIndex(of: "#") { rawId = String(rawId[..<hash]) }
    let prefixed = rawId.hasPrefix("id_")
    if prefixed { rawId = String(rawId.dropFirst(3)) }

    if rawId.contains("special/single/"), let linkId = Self.detailLinkID(rawId), !linkId.isEmpty {
      return try await getListDetailBySpecialId(linkId, page: page)
    }
    if prefixed {
      return try await getListDetailBySpecialId(rawId, page: page)
    }
    if !rawId.isEmpty, rawId.allSatisfy(\.isNumber) {
      return try await getUserListDetailByCode(rawId, page: page)
    }
    if rawId.hasPrefix("http") {
      if let linkId = Self.detailLinkID(rawId), !linkId.isEmpty {
        return try await getListDetailBySpecialId(linkId, page: page)
      }
      return try await getUserListDetail(rawId, page: page)
    }
    return try await getListDetailBySpecialId(rawId, page: page)
  }

  /// 各请求体错误码形状不统一：error_code / errcode / err_code
  private static func kgErrorCode(_ json: [String: Any], fallback: Int = 0) -> Int {
    ALHttp.int(json["error_code"]) ?? ALHttp.int(json["errcode"]) ?? ALHttp.int(json["err_code"]) ?? fallback
  }

  /// songlistDetail.ts requestWithRetry（:105-117）：校验 HTTP 200 + 统一错误码为 0。
  @discardableResult
  private static func requestWithRetry(_ urlString: String, method: String = "GET",
                                       headers: [String: String] = [:],
                                       json: [String: Any]? = nil) async throws -> [String: Any] {
    let any: Any
    if method == "POST", let json {
      any = try await ALHttp.postJSON(urlString, json: json, headers: headers)
    } else {
      any = try await ALHttp.getJSON(urlString, headers: headers, requireOK: true)
    }
    guard let root = any as? [String: Any], kgErrorCode(root) == 0 else {
      throw ALSourceError.invalidResponse("酷狗歌单请求失败")
    }
    return root
  }

  /// 与 TS `JSON.stringify` 字节一致的原始 JSON POST（decodeGcid 的 body 参与签名，键序必须一致）。
  private static func postRawJSON(_ urlString: String, body: String, headers: [String: String]) async throws -> (data: Data, response: HTTPURLResponse) {
    var req = URLRequest(url: URL(string: urlString)!, timeoutInterval: 15)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = Data(body.utf8)
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
      throw ALSourceError.invalidResponse("非 HTTP 响应")
    }
    return (data, http)
  }

  /// songlist.ts regExps.listDetailLink：取 URL 尾部的数字 id
  private static func detailLinkID(_ link: String) -> String? {
    Self.captures(pattern: #".+/(\d+)\.html(?:\?.*|&.*$|#.*$|$)"#, in: link).first
  }

  /// 按捕获组顺序返回正则结果（NSRegularExpression 版 RegExp.exec）
  private static func captures(pattern: String, in text: String,
                               options: NSRegularExpression.Options = []) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return [] }
    return (1..<match.numberOfRanges).compactMap { i in
      let range = match.range(at: i)
      guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
      return String(text[swiftRange])
    }
  }

  /// songlistDetail.ts getListDetailBySpecialId：HTML 中 global.data + global 元信息
  private static func getListDetailBySpecialId(_ id: String, page: Int) async throws -> ALSonglistDetailResult {
    let (data, response) = try await ALHttp.getRaw(
      "http://www2.kugou.kugou.com/yueku/v9/special/single/\(id)-5-9999.html")
    guard response.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
      throw ALSourceError.invalidResponse("酷狗歌单详情失败")
    }
    guard let jsonText = Self.captures(pattern: #"global\.data = (\[.+\]);"#, in: html).first,
          let hashData = jsonText.data(using: .utf8),
          let rawHashes = try? JSONSerialization.jsonObject(with: hashData) as? [[String: Any]] else {
      throw ALSourceError.invalidResponse("酷狗歌单详情解析失败")
    }
    let hashes = rawHashes.compactMap { ALHttp.str($0["hash"]) }.filter { !$0.isEmpty }
    let list = try await getMusicInfos(hashes)
    // regExps.listInfo：name / pic；parseHtmlDesc：简介 div
    let meta = Self.captures(
      pattern: #"global = \{[\s\S]+?name: "(.+)"[\s\S]+?pic: "(.+)"[\s\S]+?\};"#, in: html)
    let name = ALFormat.decodeName(meta.first ?? "")
    let pic = meta.count > 1 ? meta[1] : ""
    let introPrefix = #"<div class="pc_specail_text pc_singer_tab_content" id="specailIntroduceWrap">"#
    let desc = html.range(of: introPrefix).flatMap { range -> String? in
      let after = html[range.upperBound...]
      return after.range(of: "</div>").map { String(after[..<$0.lowerBound]) }
    }.map { ALFormat.decodeName($0) }
    let info = ALSongListDetailInfo(
      name: name, img: pic.isEmpty ? nil : expandSize(pic),
      desc: desc.flatMap { $0.isEmpty ? nil : $0 }, author: "", playCount: nil, date: nil)
    return ALSonglistDetailResult(list: list, total: list.count, page: 1, limit: limitSong, info: info)
  }

  /// songlistDetail.ts getUserListDetailByCode：分享码 → t.kugou.com/command/
  private static func getUserListDetailByCode(_ code: String, page: Int) async throws -> ALSonglistDetailResult {
    let payload: [String: Any] = [
      "appid": 1001, "clientver": 9020,
      "mid": "21511157a05844bd085308bc76ef3343", "clienttime": 640612895,
      "key": "36164c4015e704673c588ee202b9ecb8", "data": code,
    ]
    let headers = [
      "KG-RC": "1", "KG-THash": "network_super_call.cpp:3676261689:379", "User-Agent": "",
    ]
    let json = try await ALHttp.postJSON("http://t.kugou.com/command/", json: payload, headers: headers) as? [String: Any]
    guard let root = json, kgErrorCode(root, fallback: -1) == 0,
          let data = ALHttp.dict(root["data"]) else {
      throw ALSourceError.invalidResponse("酷狗分享歌单失败")
    }
    let info = ALHttp.dict(data["info"]) ?? [:]
    let gcid = ALHttp.str(info["global_collection_id"])
    // type == 2 且无 gcid：其实是 specialId，转回 special/single 链
    if ALHttp.int(info["type"]) == 2, gcid.isEmpty, !ALHttp.str(info["id"]).isEmpty {
      return try await getListDetailBySpecialId(ALHttp.str(info["id"]), page: page)
    }
    if !gcid.isEmpty {
      return try await getUserListDetail2(gcid, page: page)
    }
    let hashes = (ALHttp.arr(data["list"]) ?? []).compactMap { ALHttp.str($0["hash"]) }.filter { !$0.isEmpty }
    let list = try await getMusicInfos(hashes)
    let rawImg = ALHttp.str(info["img_size"])
    let img = rawImg.isEmpty ? ALHttp.str(info["img"]) : rawImg
    let detailInfo = ALSongListDetailInfo(
      name: ALFormat.decodeName(ALHttp.str(info["name"])),
      img: img.isEmpty ? nil : expandSize(img, size: "240"),
      desc: nil,
      author: (info["username"] as? String).map { ALFormat.decodeName($0) },
      playCount: nil, date: nil)
    return ALSonglistDetailResult(list: list, total: list.count, page: page,
                                  limit: ALHttp.int(info["count"]) ?? limitSong, info: detailInfo)
  }

  // MARK: - songlistDetail.ts gcid / chain / 分享链接级联

  /// 移动端 Web 头（扩展各 zlist/info_v2/transfer 分支原样透传）
  private static let mobileWebHeaders = [
    "Referer": "https://m3ws.kugou.com/share/index.php",
    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 11_0 like Mac OS X) AppleWebKit/604.1.38 (KHTML, like Gecko) Version/11.0 Mobile/15A372 Safari/604.1",
    "dfid": "-",
  ]

  /// decodeGcid（:119-142）：POST t.kugou.com/v1/songlist/batch_decode，body 参与 android 签名。
  private static func decodeGcid(_ gcid: String) async throws -> String {
    let params = "dfid=-&appid=1005&mid=0&clientver=20109&clienttime=640612895&uuid=-"
    // TS JSON.stringify({ret_info, data:[{id, id_type}]}) 的固定键序；body 参与签名，必须字节一致。
    let body = "{\"ret_info\":1,\"data\":[{\"id\":\"\(gcid)\",\"id_type\":2}]}"
    let signature = ALCrypto.kgSignature(params, body: body, platform: "android")
    let headers = [
      "User-Agent": "Mozilla/5.0 (Linux; Android 10; HUAWEI HMA-AL00) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Mobile Safari/537.36",
      "Referer": "https://m.kugou.com/",
    ]
    let (data, response) = try await postRawJSON(
      "https://t.kugou.com/v1/songlist/batch_decode?\(params)&signature=\(signature)",
      body: body, headers: headers)
    guard response.statusCode == 200,
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          kgErrorCode(root) == 0,
          let list = ALHttp.arr(ALHttp.dict(root["data"])?["list"]),
          let first = list.first else {
      throw ALSourceError.invalidResponse("酷狗 gcid 解码失败")
    }
    let collectionId = ALHttp.str(first["global_collection_id"])
    guard !collectionId.isEmpty else {
      throw ALSourceError.invalidResponse("酷狗 gcid 解码失败")
    }
    return collectionId
  }

  /// getListDetailByGcid（:144-151）：pubsongscdn get_other_list_file 单页 → hash 数组。
  private static func getListDetailByGcid(_ id: String, page: Int, limit: Int) async throws -> [String] {
    let params = "specialid=0&need_sort=1&module=CloudMusic&clientver=11409&pagesize=\(limit)" +
      "&global_collection_id=\(id)&userid=0&page=\(page)&type=1&area_code=1&appid=1005"
    let signature = ALCrypto.kgSignature(params)
    let root = try await requestWithRetry(
      "http://pubsongscdn.tx.kugou.com/v2/get_other_list_file?\(params)&signature=\(signature)")
    guard let info = ALHttp.arr(ALHttp.dict(root["data"])?["info"]) else {
      throw ALSourceError.invalidResponse("酷狗歌单 gcid 列表失败")
    }
    return info.compactMap { ALHttp.str($0["hash"]) }.filter { !$0.isEmpty }
  }

  /// createGetListDetail2Task（:153-165）：按 300/页并发拉全部分页 hash。
  private static func createGetListDetail2Task(_ id: String, total: Int) async throws -> [String] {
    guard total > 0 else { return [] }
    let limit = min(300, total)
    var hashes: [String] = []
    var remaining = total
    var page = 1
    while remaining > 0 {
      hashes.append(contentsOf: try await getListDetailByGcid(id, page: page, limit: limit))
      remaining -= limit
      page += 1
    }
    return hashes
  }

  /// getUserListDetail2（:225-273）：info_v2 元信息 + 300/页 gcid 列表。
  private static func getUserListDetail2(_ globalCollectionId: String, page: Int) async throws -> ALSonglistDetailResult {
    guard globalCollectionId.count <= 1000 else {
      throw ALSourceError.invalidResponse("酷狗歌单 gcid 过长")
    }
    let infoParams = "appid=1058&specialid=0&global_specialid=\(globalCollectionId)" +
      "&format=jsonp&srcappid=2919&clientver=20000&clienttime=1586163242519&mid=1586163242519&uuid=1586163242519&dfid=-"
    let infoSig = ALCrypto.kgSignature(infoParams, platform: "web")
    var headers = mobileWebHeaders
    headers["mid"] = "1586163242519"
    headers["clienttime"] = "1586163242519"
    let root = try await requestWithRetry(
      "https://mobiles.kugou.com/api/v5/special/info_v2?\(infoParams)&signature=\(infoSig)", headers: headers)
    guard let data = ALHttp.dict(root["data"]) else {
      throw ALSourceError.invalidResponse("酷狗歌单 gcid 信息失败")
    }
    let songcount = ALHttp.int(data["songcount"]) ?? 0
    let hashes = try await createGetListDetail2Task(globalCollectionId, total: songcount)
    let list = try await getMusicInfos(hashes)
    let rawImg = ALHttp.str(data["imgurl"])
    let intro = ALFormat.decodeName(ALHttp.str(data["intro"]))
    let detailInfo = ALSongListDetailInfo(
      name: ALFormat.decodeName(ALHttp.str(data["specialname"])),
      img: rawImg.isEmpty ? nil : expandSize(rawImg, size: "240"),
      desc: intro.isEmpty ? nil : intro,
      author: (data["nickname"] as? String).map { ALFormat.decodeName($0) },
      playCount: ALNormalize.playCount(data["playcount"]),
      date: Self.dateOnly(ALHttp.str(data["publishtime"])))
    return ALSonglistDetailResult(list: list, total: list.count, page: page,
                                  limit: limitSong, info: detailInfo)
  }

  /// getListDetailByGcidChain（:167-223）：m3ws zlist/list，带 mid/Referer/UA/dfid/clienttime 头，
  /// 按 50/页分页；info.name/pic{size}→240/intro/list_create_username。
  private static func getListDetailByGcidChain(_ id: String, chain: String) async throws -> ALSonglistDetailResult {
    let limit = 50
    func params(_ page: Int) -> String {
      "srcappid=2919&clientver=20000&clienttime=1789566751657&mid=1789566751657&uuid=1789566751657&dfid=-" +
        "&listid=15&type=0&pagesize=\(limit)&global_collection_id=\(id)&page=\(page)" +
        "&share_type=collect&appid=1058&chain=\(chain)"
    }
    var headers = mobileWebHeaders
    headers["mid"] = "1586163263991"
    headers["clienttime"] = "1586163263991"
    func fetch(_ page: Int) async throws -> [String: Any] {
      let p = params(page)
      let sig = ALCrypto.kgSignature(p, platform: "web")
      return try await requestWithRetry("https://m3ws.kugou.com/v2/zlist/list?\(p)&signature=\(sig)", headers: headers)
    }
    let first = try await fetch(1)
    guard let info = (ALHttp.arr(first["info"]) ?? []).first else {
      throw ALSourceError.invalidResponse("酷狗歌单 chain 信息为空")
    }
    let count = ALHttp.int(info["count"]) ?? 0
    var hashes = (ALHttp.arr(ALHttp.dict(first["list"])?["info"]) ?? [])
      .compactMap { ALHttp.str($0["hash"]) }.filter { !$0.isEmpty }
    let totalPage = Int(ceil(Double(count) / Double(limit)))
    if totalPage > 1 {
      for page in 2...totalPage {
        let resp = try await fetch(page)
        hashes.append(contentsOf: (ALHttp.arr(ALHttp.dict(resp["list"])?["info"]) ?? [])
          .compactMap { ALHttp.str($0["hash"]) }.filter { !$0.isEmpty })
      }
    }
    let list = try await getMusicInfos(hashes)
    let pic = ALHttp.str(info["pic"])
    let detailInfo = ALSongListDetailInfo(
      name: ALFormat.decodeName(ALHttp.str(info["name"])),
      img: pic.isEmpty ? nil : expandSize(pic, size: "240"),
      desc: ALHttp.str(info["intro"]),
      author: ALHttp.str(info["list_create_username"]),
      playCount: nil, date: nil)
    return ALSonglistDetailResult(list: list, total: count, page: 1,
                                  limit: list.count, info: detailInfo)
  }

  /// getListInfoByChain（:275-291）：m.kugou.com/share 页 var phpParam JSON。
  private static func getListInfoByChain(_ chain: String) async throws -> [String: Any] {
    let (data, response) = try await ALHttp.getRaw(
      "https://m.kugou.com/share/?chain=\(chain)&id=\(chain)",
      headers: ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1"])
    guard response.statusCode == 200, let html = String(data: data, encoding: .utf8),
          let jsonText = Self.captures(pattern: #"var\sphpParam\s=\s(\{.+?\});"#, in: html).first,
          let jd = jsonText.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any] else {
      throw ALSourceError.invalidResponse("酷狗 chain 信息失败")
    }
    return obj
  }

  /// getUserListDetailByPcChain（:293-307）：www.kugou.com/share/<chain>.html var dataFromSmarty JSON。
  private static func getUserListDetailByPcChain(_ chain: String) async throws -> [MusicInfo] {
    let (data, response) = try await ALHttp.getRaw(
      "http://www.kugou.com/share/\(chain).html",
      headers: ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36"])
    guard response.statusCode == 200, let html = String(data: data, encoding: .utf8),
          let jsonText = Self.captures(pattern: #"var\sdataFromSmarty\s=\s(\[.+?\])"#, in: html).first,
          let jd = jsonText.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: jd) as? [[String: Any]] else {
      throw ALSourceError.invalidResponse("酷狗 PC chain 失败")
    }
    return try await getMusicInfos(arr.compactMap { ALHttp.str($0["hash"]) }.filter { !$0.isEmpty })
  }

  /// chain 系分支共用的歌单信息（:319-332 / :384-396）。
  private static func chainListInfo(_ d: [String: Any]) -> ALSongListDetailInfo {
    let raw = ALHttp.str(d["imgurl"])
    return ALSongListDetailInfo(
      name: ALFormat.decodeName(ALHttp.str(d["specialname"])),
      img: raw.isEmpty ? nil : expandSize(raw, size: "240"),
      desc: nil,
      author: (d["nickname"] as? String).map { ALFormat.decodeName($0) },
      playCount: nil, date: nil)
  }

  /// getUserListDetail5（:309-333）：chain 分享页信息 + PC chain 歌曲。
  private static func getUserListDetail5(_ chain: String, page: Int) async throws -> ALSonglistDetailResult {
    let listInfo = try await getListInfoByChain(chain)
    let list = try await getUserListDetailByPcChain(chain)
    return ALSonglistDetailResult(list: list, total: list.count, page: page,
                                  limit: limitSong, info: chainListInfo(listInfo))
  }

  /// getUserListDetailById（:335-362）：pubsongscdn get_other_list_file（specialid 形态）。
  private static func getUserListDetailById(_ id: String, page: Int, limit: Int) async throws -> [MusicInfo] {
    let params = "srcappid=2919&clientver=20000&appid=1058&type=0&module=playlist" +
      "&page=\(page)&pagesize=\(limit)&specialid=\(id)"
    let signature = ALCrypto.kgSignature(params, platform: "web")
    let root = try await requestWithRetry(
      "https://pubsongscdn.kugou.com/v2/get_other_list_file?\(params)&signature=\(signature)",
      headers: mobileWebHeaders)
    let info = ALHttp.arr(root["info"]) ?? []
    let hashes = info.compactMap { ALHttp.str($0["hash"]) }.filter { !$0.isEmpty }
    return try await getMusicInfos(hashes)
  }

  /// getUserListDetail4（:364-397）：chain 信息 + transfer.info.id 对应歌曲。
  private static func getUserListDetail4(_ songInfo: [String: Any], chain: String,
                                         page: Int) async throws -> ALSonglistDetailResult {
    let listInfo = try await getListInfoByChain(chain)
    let idValue = songInfo["id"]
    let hasId = idValue is String || idValue is NSNumber || idValue is Int
    let list = hasId ? try await getUserListDetailById(ALHttp.str(idValue), page: page, limit: 100) : []
    return ALSonglistDetailResult(list: list, total: list.count, page: page,
                                  limit: 100, info: chainListInfo(listInfo))
  }

  /// getUserListDetail3（:399-442）：schain/transfer 分发到 gcid-chain / v2 / byId / chain-5 兜底。
  private static func getUserListDetail3(_ chain: String, page: Int) async throws -> ALSonglistDetailResult {
    let root = try await requestWithRetry(
      "http://m.kugou.com/schain/transfer?pagesize=\(limitSong)&chain=\(chain)&su=1&page=\(page)&n=0.7928855356604456",
      headers: ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Version/9.0 Mobile/13B143 Safari/601.1"])
    guard let songInfo = ALHttp.dict(root["info"]) else {
      throw ALSourceError.invalidResponse("酷狗 schain 信息失败")
    }
    let songList = ALHttp.arr(songInfo["list"]) ?? []
    if songList.isEmpty {
      let gcid = ALHttp.str(songInfo["global_collection_id"])
      if !gcid.isEmpty {
        do { return try await getListDetailByGcidChain(gcid, chain: chain) }
        catch { return try await getUserListDetail2(gcid, page: page) }
      }
      do { return try await getUserListDetail4(songInfo, chain: chain, page: page) }
      catch { return try await getUserListDetail5(chain, page: page) }
    }
    let hashes = songList.compactMap { ALHttp.str($0["hash"]) }.filter { !$0.isEmpty }
    let list = try await getMusicInfos(hashes)
    let nested = ALHttp.dict(songInfo["info"]) ?? [:]
    let name = ALHttp.str(nested["name"])
    let img = ALHttp.str(nested["img"])
    let detailInfo = ALSongListDetailInfo(
      name: name.isEmpty ? "未命名歌单" : ALFormat.decodeName(name),
      img: img.isEmpty ? nil : img,
      desc: nil,
      author: ALHttp.str(nested["username"]),
      playCount: nil, date: nil)
    return ALSonglistDetailResult(list: list, total: list.count, page: page,
                                  limit: limitSong, info: detailInfo)
  }

  /// 禁止自动跟随重定向的会话代理（TS request maxRedirect:0 读取 Location 头）。
  private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
      completionHandler(nil)
    }
  }

  private static func getRawNoRedirect(_ urlString: String) async throws -> (data: Data, response: HTTPURLResponse) {
    let delegate = NoRedirectDelegate()
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var req = URLRequest(url: URL(string: urlString)!, timeoutInterval: 15)
    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Version/9.0 Mobile/13B143 Safari/601.1", forHTTPHeaderField: "User-Agent")
    req.setValue(urlString, forHTTPHeaderField: "Referer")
    let (data, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
      throw ALSourceError.invalidResponse("非 HTTP 响应")
    }
    return (data, http)
  }

  /// getUserListDetail（:495-570）：分享/短链接的完整级联（chain/gcid/zlist/重定向/页面内 gcid）。
  private static func getUserListDetail(_ link: String, page: Int, depth: Int = 0) async throws -> ALSonglistDetailResult {
    guard depth < 8 else { throw ALSourceError.invalidResponse("酷狗歌单重定向过多") }
    var rawLink = link
    if let h = rawLink.range(of: #"#.*$"#, options: .regularExpression) {
      rawLink = String(rawLink[..<h.lowerBound])
    }

    // global_collection_id + chain 同时出现 → gcid chain 直连
    if rawLink.contains("global_collection_id"), rawLink.contains("chain") {
      let gcid = Self.captures(pattern: #"^.*?global_collection_id=(\w+)(?:&.*$|#.*$|$)"#, in: rawLink).first ?? ""
      let chain = Self.captures(pattern: #"^.*?chain=(\w+)(?:&.*$|#.*$|$)"#, in: rawLink).first ?? ""
      return try await getListDetailByGcidChain(gcid, chain: chain)
    }
    // gcid_xxx → batch_decode → v2
    if let encoded = Self.captures(pattern: #"(gcid_\w+)"#, in: rawLink).first {
      return try await getUserListDetail2(try await decodeGcid(encoded), page: page)
    }
    // chain=xxx → schain/transfer 级联
    if rawLink.contains("chain=") {
      let chain = Self.captures(pattern: #"^.*?chain=(\w+)(?:&.*$|#.*$|$)"#, in: rawLink).first ?? ""
      return try await getUserListDetail3(chain, page: page)
    }
    // .html 链接：zlist 改写分页；其余非 song.html 按 chain 处理
    if rawLink.contains(".html") {
      if rawLink.contains("zlist.html") {
        if let r = rawLink.range(of: #"^(.*)zlist\.html"#, options: .regularExpression) {
          rawLink = "https://m3ws.kugou.com/zlist/list" + String(rawLink[r.upperBound...])
        }
        if rawLink.contains("pagesize") {
          rawLink = rawLink.replacingOccurrences(of: "pagesize=30", with: "pagesize=\(limitSong)")
            .replacingOccurrences(of: "page=1", with: "page=\(page)")
        } else {
          rawLink += "&pagesize=\(limitSong)&page=\(page)"
        }
      } else if !rawLink.contains("song.html") {
        let chain = Self.captures(pattern: #".+/(\w+)\.html(?:\?.*|&.*$|#.*$|$)"#, in: rawLink).first ?? ""
        return try await getUserListDetail3(chain, page: page)
      }
    }
    if rawLink.contains("global_collection_id") {
      let gcid = Self.captures(pattern: #"^.*?global_collection_id=(\w+)(?:&.*$|#.*$|$)"#, in: rawLink).first ?? ""
      return try await getUserListDetail2(gcid, page: page)
    }

    // 无现成 id：原始请求，按 Location 跳转；再从页面内提取 gcid / encode_gid
    let (data, response) = try await getRawNoRedirect(rawLink)
    guard response.statusCode < 400 else {
      throw ALSourceError.invalidResponse("酷狗歌单链接失败")
    }
    if let location = response.value(forHTTPHeaderField: "Location"), !location.isEmpty {
      return try await getUserListDetail(location, page: page, depth: depth + 1)
    }
    let body = String(data: data, encoding: .utf8) ?? ""
    var gcid = Self.captures(pattern: #""global_collection_id":"(\w+)""#, in: body).first ?? ""
    if gcid.isEmpty {
      var encoded = Self.captures(pattern: #""encode_gic":"(\w+)""#, in: body).first ?? ""
      if encoded.isEmpty { encoded = Self.captures(pattern: #""encode_src_gid":"(\w+)""#, in: body).first ?? "" }
      if !encoded.isEmpty { gcid = try await decodeGcid(encoded) }
    }
    guard !gcid.isEmpty else { throw ALSourceError.invalidResponse("酷狗歌单链接失败") }
    return try await getUserListDetail2(gcid, page: page)
  }

  // MARK: - musicDetail.ts getMusicInfos（gateway.kugou.com/v2/album_audio/audio）

  private static func musicDetailHeaders() -> [String: String] {
    [
      "KG-THash": "13a3164", "KG-RC": "1", "KG-Fake": "0", "KG-RF": "00869891",
      "User-Agent": "Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi",
      "x-router": "kmr.service.kugou.com",
    ]
  }

  /// 按 100/批查询歌曲详情；逐档 hash + size 才声明音质，按 audio_id 去重
  private static func getMusicInfos(_ hashes: [String]) async throws -> [MusicInfo] {
    let unique = ALNormalize.dedup(hashes.filter { !$0.isEmpty }, id: { $0 })
    guard !unique.isEmpty else { return [] }
    let clienttime = Int(Date().timeIntervalSince1970 * 1000)
    var result: [MusicInfo] = []
    for start in stride(from: 0, to: unique.count, by: 100) {
      let batch = Array(unique[start..<min(start + 100, unique.count)])
      let task: [String: Any] = [
        "area_code": "1", "show_privilege": 1, "show_album_info": "1", "is_publish": "",
        "appid": 1005, "clientver": 11451, "mid": "1", "dfid": "-", "clienttime": clienttime,
        "key": "OIlwieks28dk2k092lksi2UIkp",
        "fields": "album_info,author_name,audio_info,ori_audio_name,base,songname",
        "data": batch.map { ["hash": $0] },
      ]
      let json = try await ALHttp.postJSON("http://gateway.kugou.com/v2/album_audio/audio",
                                           json: task, headers: musicDetailHeaders()) as? [String: Any]
      guard let root = json, kgErrorCode(root, fallback: -1) == 0,
            let raw = root["data"] as? [Any] else {
        throw ALSourceError.invalidResponse("酷狗歌曲详情失败")
      }
      for entry in raw {
        guard let group = entry as? [Any], let first = group.first as? [String: Any],
              let music = mapMusicDetail(first) else { continue }
        result.append(music)
      }
    }
    return ALNormalize.dedup(result, id: { $0.songmid })
  }

  /// musicDetail.ts filterData2：audio_info 四档 hash/filesize + timelength(毫秒)
  private static func mapMusicDetail(_ item: [String: Any]) -> MusicInfo? {
    let audio = ALHttp.dict(item["audio_info"]) ?? [:]
    let album = ALHttp.dict(item["album_info"]) ?? [:]
    let audioId = ALHttp.str(audio["audio_id"])
    guard !audioId.isEmpty else { return nil }
    let hash = ALHttp.str(audio["hash"])
    let hqHash = ALHttp.str(audio["hash_320"])
    let sqHash = ALHttp.str(audio["hash_flac"])
    let resHash = ALHttp.str(audio["hash_high"])
    func quality(_ size: Any?, _ hash: String, _ type: MusicQuality) -> MusicQualityType? {
      guard !hash.isEmpty, let n = ALHttp.int(size), n > 0 else { return nil }
      return MusicQualityType(type: type, size: ALFormat.sizeFormate(n))
    }
    var quals: [MusicQualityType] = []
    if let q = quality(audio["filesize"], hash, .q128k) { quals.append(q) }
    if let q = quality(audio["filesize_320"], hqHash, .q320k) { quals.append(q) }
    if let q = quality(audio["filesize_flac"], sqHash, .flac) { quals.append(q) }
    if let q = quality(audio["filesize_high"], resHash, .flac24bit) { quals.append(q) }
    let secs = Int((ALHttp.double(audio["timelength"]) ?? 0) / 1000)
    let rawName = ALHttp.str(item["songname"])
    let name = ALFormat.decodeName(rawName.isEmpty ? ALHttp.str(item["ori_audio_name"]) : rawName)
    return MusicInfo(
      name: name, singer: ALFormat.decodeName(ALHttp.str(item["author_name"])),
      source: .kg, songmid: audioId,
      albumName: ALFormat.decodeName(ALHttp.str(album["album_name"])),
      interval: ALFormat.playTime(secs),
      qualitys: quals.isEmpty ? [MusicQualityType(type: .q128k, size: nil)] : quals,
      picUrl: nil,
      extra: ["hash": hash, "hqHash": hqHash, "sqHash": sqHash, "resHash": resHash,
              "albumAudioId": ALHttp.str(audio["audio_group_id"]),
              "albumId": ALHttp.str(album["album_id"]), "intervalSecs": "\(secs)"])
  }

  // MARK: 歌词（krc 逐字解码；候选需 hash + 时长命中）

  static func musicLyric(_ music: MusicInfo) async throws -> LyricInfo {
    let hash = music.extra?["hash"] ?? ""
    // 扩展传 meta._interval（秒）；无该字段时回退解析 mm:ss。注意单位为秒，不是毫秒。
    let secs: Int = {
      if let raw = music.extra?["intervalSecs"], let v = Int(raw), v > 0 { return v }
      return Self.intv(from: music.interval)
    }()
    let headers = ["KG-RC": "1", "KG-THash": "expand_search_manager.cpp:852736169:451",
                   "User-Agent": "KuGou2012-9020-ExpandSearchManager"]
    let q = encodeURIComponent(music.name)
    let s = try await ALHttp.getJSON(
      "http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=\(q)&hash=\(hash)&timelength=\(secs)&lrctxt=1",
      headers: headers) as? [String: Any]
    guard let candidates = s?["candidates"] as? [[String: Any]], let c = candidates.first else {
      throw ALSourceError.invalidResponse("酷狗歌词候选为空")
    }
    // 扩展只选 candidates[0]：krctype==1 且 contenttype!=1 → krc，否则 lrc
    let id = ALHttp.str(c["id"])
    let accesskey = ALHttp.str(c["accesskey"])
    let krctype = ALHttp.int(c["krctype"]) ?? 1
    let contenttype = ALHttp.int(c["contenttype"]) ?? 0
    guard !id.isEmpty, !accesskey.isEmpty else {
      throw ALSourceError.invalidResponse("酷狗歌词下载失败")
    }
    let fmt = (krctype == 1 && contenttype != 1) ? "krc" : "lrc"
    guard let d = try? await ALHttp.getJSON(
      "http://lyrics.kugou.com/download?ver=1&client=pc&id=\(id)&accesskey=\(accesskey)&fmt=\(fmt)&charset=utf8",
      headers: headers) as? [String: Any],
          let b64 = d["content"] as? String,
          let data = Data(base64Encoded: b64), !data.isEmpty else {
      throw ALSourceError.invalidResponse("酷狗歌词下载失败")
    }
    // 扩展按响应 body.fmt 分支（不是请求 fmt）
    switch ALHttp.str(d["fmt"]) {
    case "krc":
      guard let krc = LyricCodec.decodeKRC(data) else {
        throw ALSourceError.invalidResponse("酷狗 KRC 解码失败")
      }
      let text = ALFormat.decodeName(LyricCodec.krcToLrc(krc))
      // lxlyric 保留逐字标签原文（含 <a,b,0>），供 karaoke 使用
      return LyricInfo(lyric: text, tlyric: nil, rlyric: nil, lxlyric: text)
    case "lrc":
      guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
        throw ALSourceError.invalidResponse("酷狗 LRC 解码失败")
      }
      return LyricInfo(lyric: ALFormat.decodeName(text), tlyric: nil, rlyric: nil, lxlyric: nil)
    default:
      throw ALSourceError.invalidResponse("未知歌词格式: \(ALHttp.str(d["fmt"]))")
    }
  }

  // MARK: 封面（搜索自带 Image；榜单歌曲无图时用歌手头像兜底）

  static func musicPic(_ music: MusicInfo) async -> String? {
    music.picUrl
  }

  // MARK: - 热搜词 / 搜索提示（kg/hotSearch.ts + kg/tipSearch.ts）

  /// hotSearch.ts search：hot_tab（签名固定，头信息按扩展原样透传）
  static func hotSearch() async throws -> [String] {
    let url = "http://gateway.kugou.com/api/v3/search/hot_tab?signature=ee44edb9d7155821412d220bcaf509dd&appid=1005&clientver=10026&plat=0"
    let headers = [
      "dfid": "1ssiv93oVqMp27cirf2CvoF1",
      "mid": "156798703528610303473757548878786007104",
      "clienttime": "1584257267",
      "x-router": "msearch.kugou.com",
      "user-agent": "Android9-AndroidPhone-10020-130-0-searchrecommendprotocol-wifi",
      "kg-rc": "1",
    ]
    let json = try await ALHttp.getJSON(url, headers: headers, requireOK: true) as? [String: Any]
    guard let root = json, ALHttp.int(root["errcode"]) == 0 else {
      throw ALSourceError.invalidResponse("酷狗热搜失败")
    }
    var result: [String] = []
    for item in ALHttp.arr(ALHttp.dict(root["data"])?["list"]) ?? [] {
      for keyword in ALHttp.arr(item["keywords"]) ?? [] {
        let word = ALHttp.str(keyword["keyword"])
        if !word.isEmpty { result.append(ALFormat.decodeName(word)) }
      }
    }
    return result
  }

  /// tipSearch.ts search：getSearchTip → RecordDatas[].HintInfo
  static func tipSearch(keyword: String) async throws -> [String] {
    let q = encodeURIComponent(keyword)
    let json = try await ALHttp.getJSON(
      "https://searchtip.kugou.com/getSearchTip?MusicTipCount=10&keyword=\(q)",
      headers: ["Referer": "https://www.kugou.com/"], requireOK: true) as? [String: Any]
    guard let root = json, ALHttp.int(root["error_code"]) == 0,
          let data = ALHttp.arr(root["data"]), let first = data.first else {
      throw ALSourceError.invalidResponse("酷狗搜索提示失败")
    }
    return (ALHttp.arr(first["RecordDatas"]) ?? [])
      .map { ALHttp.str($0["HintInfo"]) }
      .filter { !$0.isEmpty }
  }

  // MARK: 播放直链（kg 扩展未声明 musicUrl 动作；Swift 侧降级返回 nil）

  static func musicUrl(_ music: MusicInfo, chain: [Int]) async -> ALMusicUrlInfo? { nil }
}
