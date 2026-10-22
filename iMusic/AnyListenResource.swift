import Foundation

// MARK: - any-listen 解析契约层（音源底层 · 严格对齐 any-listen）
//
// 复刻自 any-listen 仓库（submodule @any-listen）的解析逻辑契约：
//   types/extension_ipc.d.ts    ResourceAction：musicSearch / songlistSorts / songlistTags /
//                                songlist / songlistSearch / songlistDetail / topSongs /
//                                topSongsDate / topSongsDetail / musicLyric / musicPic / musicUrl
//   types/resource.d.ts          SongListItem / SongListDetailInfo / TagItem / TagGroupItem /
//                                TopSongsItem / TopSongsDetailInfo
//   types/music.d.ts             MusicInfoOnline.meta（musicId/albumName/picUrl/qualitys）/
//                                LyricInfo（lyric/tlyric/rlyric/awlyric）/ Quality→FileType
//   app/modules/resources/*      分发与 ListCommonResult 归一化（list/total/page/limit、去重）
//
// 与 any-listen 的分工一致（app 本体不含站点解析、解析由资源提供方完成）：
//   · 搜索/歌单/榜单/歌词/封面：本层直连各站公开接口解析（any-listen 生态里由
//     GD音乐台/LX 系源脚本完成的部分），归一化成 any-listen 数据形状；
//   · 播放直链：主路径仍走自定义源（UserApiEngine，对标 any-listen 的
//     lx-api-source-loader），本层只做与 GD音乐台同源的降级兜底（types=url + br 链）。
//
// 本文件不含任何 UI 依赖（Foundation only），可被 CLI 探针单独编译验证。

// MARK: any-listen 契约类型（AnyListen.Resource.* / AnyListen.IPCExtension.*）

/// Resource.CommonItem / TagItem
struct ALTagItem: Hashable, Sendable {
  var id: String
  var name: String
}

/// Resource.TagGroupItem（歌单标签分组）
struct ALTagGroupItem: Hashable, Sendable {
  var name: String
  var list: [ALTagItem]
}

/// IPCExtension.SonglistTagResult
struct ALSonglistTagResult: Sendable {
  var tags: [ALTagGroupItem]
  var hotTags: [ALTagItem]
}

/// Resource.SongListItem（在线歌单条目）
struct ALSongListItem: Hashable, Sendable {
  var id: String
  var name: String
  var playCount: String?
  var author: String?
  var time: String?
  var img: String?
  var desc: String?
  var total: Int?
}

/// Resource.SongListDetailInfo
struct ALSongListDetailInfo: Hashable, Sendable {
  var name: String
  var img: String?
  var desc: String?
  var author: String?
  var playCount: String?
  var date: String?
}

/// Resource.TopSongsItem（排行榜条目，CommonItem + pic）
struct ALTopSongsItem: Hashable, Sendable {
  var id: String
  var name: String
  var pic: String?
}

/// Resource.TopSongsDetailInfo
struct ALTopSongsDetailInfo: Hashable, Sendable {
  var name: String
  var pic: String?
  var desc: String?
  var date: String?
}

/// IPCExtension.ListCommonResult<T>
struct ALListResult<T> {
  var list: [T]
  var total: Int
  var page: Int
  var limit: Int

  init(list: [T], total: Int, page: Int, limit: Int) {
    self.list = list
    self.total = total
    self.page = page
    self.limit = limit
  }
}

/// IPCExtension.SonglistDetailResult / TopSongsDetailResult
struct ALSonglistDetailResult {
  var list: [MusicInfo]
  var total: Int
  var page: Int
  var limit: Int
  var info: ALSongListDetailInfo
}

struct ALTopSongsDetailResult {
  var list: [MusicInfo]
  var total: Int
  var page: Int
  var limit: Int
  var info: ALTopSongsDetailInfo
}

/// IPCExtension.MusicUrlInfo
struct ALMusicUrlInfo {
  var url: String
  var quality: MusicQuality
}

/// Music.LyricInfo（iMusic 的 LyricInfo 即 its lyric/tlyric/rlyric/lxlyric 四元组）
typealias ALLyricResult = LyricInfo

// MARK: - any-listen 归一化工具（复刻 gdstudio 源扩展的 buildMusicInfo/格式化）

/// 与 any-listen Music.Quality ↔ GD br 档位一一对应（gdstudio 源扩展 qualityToBr/brToQuality）
enum ALQualityBridge {
  static func toBr(_ quality: MusicQuality) -> Int {
    switch quality {
    case .q128k: return 128
    case .q320k: return 320
    case .flac: return 740
    case .flac24bit: return 999
    }
  }

  static func fromBr(_ br: Int) -> MusicQuality {
    if br >= 999 { return .flac24bit }
    if br >= 740 { return .flac }
    if br >= 320 { return .q320k }
    return .q128k
  }

  /// gdstudio buildQualitysFromBr：从实际可用 br 生成「该档及以下全部音质」声明
  static func qualitys(fromBr br: Int) -> [MusicQualityType] {
    var qs: [MusicQualityType] = [.init(type: .q128k, size: nil)]
    if br >= 192 { qs.append(.init(type: .q320k, size: nil)) }
    if br >= 320 { qs.append(.init(type: .q320k, size: nil)) }
    if br >= 740 { qs.append(.init(type: .flac, size: nil)) }
    if br >= 999 { qs.append(.init(type: .flac24bit, size: nil)) }
    return qs
  }

  /// 播放降级链（gdstudio musicUrl：从用户偏好档及以下逐档尝试）
  static func degradeChain(from quality: MusicQuality?) -> [Int] {
    let all = [999, 740, 320, 128]
    guard let q = quality else { return all }
    let preferred = toBr(q)
    return all.filter { $0 <= preferred }
  }
}

enum ALNormalize {
  /// gdstudio parseArtist：数组用「、」连接；字符串按分隔符拆分再连接
  static func parseArtist(_ artist: Any?) -> String {
    if let arr = artist as? [Any] {
      return arr.compactMap { ($0 as? String) ?? nil }.joined(separator: "、")
    }
    if artist == nil { return "" }
    let s = "\(artist!)"
    return s.split(whereSeparator: { "、&_;/,，|".contains($0) })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: "、")
  }

  /// gdstudio formatInterval：秒 → mm:ss / h:mm:ss（any-listen interval 形状）
  static func formatInterval(_ seconds: Any?) -> String? {
    guard let n = seconds as? Int ?? (seconds as? NSNumber)?.intValue ?? Int("\(seconds ?? "")"),
          n > 0 else { return nil }
    let h = n / 3600, m = n % 3600 / 60, s = n % 60
    if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
  }

  /// any-listen common/tools deduplicationList（按 id 保留首个）
  static func dedup<T>(_ list: [T], id: (T) -> String) -> [T] {
    var seen = Set<String>()
    var out: [T] = []
    for item in list where seen.insert(id(item)).inserted { out.append(item) }
    return out
  }

  /// 数字千分位播放量（any-listen 榜单/歌单 play_count 形状 "1.4亿"/"14,196,209"）
  static func playCount(_ n: Any?) -> String? {
    guard let v = n as? Int ?? (n as? NSNumber)?.intValue ?? Int("\(n ?? "")") else { return nil }
    if v >= 100_000_000 { return String(format: "%.1f亿", Double(v) / 100_000_000) }
    if v >= 10_000 { return String(format: "%.1f万", Double(v) / 10_000) }
    return "\(v)"
  }
}

// MARK: - 资源动作分发（对标 any-listen app/modules/resources/* 的统一入口）

/// any-listen 解析层唯一入口。所有解析实现位于 AnyListen{Kw,Kg,Tx,Wy,Mg}.swift，
/// 对外只暴露本分发器（UI/注册表通过 SourceRegistry 闭包接入，签名不变）。
enum AnyListenResource {
  /// 搜索（musicSearch：name + artist + page/limit → ListCommonResult）
  static func musicSearch(source: MusicSource, name: String, artist: String? = nil,
                          page: Int = 1, limit: Int = 30) async throws -> ALListResult<MusicInfo> {
    let kw = (artist?.isEmpty == false) ? "\(name) \(artist!)" : name
    switch source {
    case .kw: return try await AnyListenKw.musicSearch(keyword: kw, page: page, limit: limit)
    case .kg: return try await AnyListenKg.musicSearch(keyword: kw, page: page, limit: limit)
    case .tx: return try await AnyListenTx.musicSearch(keyword: name, page: page, limit: limit)
    case .wy: return try await AnyListenWy.musicSearch(keyword: kw, page: page, limit: limit)
    case .mg: return try await AnyListenMg.musicSearch(keyword: kw, page: page, limit: limit)
    case .local: throw ALSourceError.unsupported(source)
    }
  }

  /// 热搜词（hotSearch → string[]；仅网易有公开免费接口，其余源返回固定推荐词）
  static func hotSearch(source: MusicSource) async -> [String] {
    switch source {
    case .wy: return (try? await AnyListenWy.hotSearch()) ?? Self.defaultHotWords
    default: return Self.defaultHotWords
    }
  }

  static let defaultHotWords = ["周杰伦", "林俊杰", "陈奕迅", "薛之谦", "邓紫棋", "陶喆", "王菲", "许嵩"]

  // MARK: 歌单（songlist*：对标 any-listen 歌单浏览链路）

  static func songlistTags(source: MusicSource) async -> ALSonglistTagResult {
    switch source {
    case .wy: return await AnyListenWy.songlistTags()
    case .kg: return await AnyListenKg.songlistTags()
    case .tx: return await AnyListenTx.songlistTags()
    case .mg: return await AnyListenMg.songlistTags()
    default: return ALSonglistTagResult(tags: [], hotTags: [])
    }
  }

  static func songlistSorts(source: MusicSource) async -> [ALTagItem] {
    switch source {
    case .wy: return await AnyListenWy.songlistSorts()
    case .kg: return await AnyListenKg.songlistSorts()
    case .tx: return await AnyListenTx.songlistSorts()
    case .mg: return await AnyListenMg.songlistSorts()
    default: return []
    }
  }

  /// 按标签浏览歌单（songlist：sort + tag + page/limit）
  static func songlist(source: MusicSource, sort: String, tag: String,
                        page: Int = 1, limit: Int = 30) async throws -> ALListResult<ALSongListItem> {
    switch source {
    case .wy: return try await AnyListenWy.songlist(sort: sort, tag: tag, page: page, limit: limit)
    case .kg: return try await AnyListenKg.songlist(sort: sort, tag: tag, page: page, limit: limit)
    case .tx: return try await AnyListenTx.songlist(sort: sort, tag: tag, page: page, limit: limit)
    case .mg: return try await AnyListenMg.songlist(sort: sort, tag: tag, page: page, limit: limit)
    default: throw ALSourceError.unsupported(source)
    }
  }

  /// 歌单搜索（songlistSearch：keyword + page/limit）
  static func songlistSearch(source: MusicSource, keyword: String,
                              page: Int = 1, limit: Int = 30) async throws -> ALListResult<ALSongListItem> {
    switch source {
    case .wy: return try await AnyListenWy.songlistSearch(keyword: keyword, page: page, limit: limit)
    case .kg: return try await AnyListenKg.songlistSearch(keyword: keyword, page: page, limit: limit)
    case .tx: return try await AnyListenTx.songlistSearch(keyword: keyword, page: page, limit: limit)
    case .mg: return try await AnyListenMg.songlistSearch(keyword: keyword, page: page, limit: limit)
    default: throw ALSourceError.unsupported(source)
    }
  }

  /// 歌单详情（songlistDetail：id + page/limit → 歌曲列表 + 歌单信息）
  static func songlistDetail(source: MusicSource, id: String,
                             page: Int = 1, limit: Int = 100) async throws -> ALSonglistDetailResult {
    switch source {
    case .wy: return try await AnyListenWy.songlistDetail(id: id, page: page, limit: limit)
    case .kg: return try await AnyListenKg.songlistDetail(id: id, page: page, limit: limit)
    case .tx: return try await AnyListenTx.songlistDetail(id: id, page: page, limit: limit)
    case .mg: return try await AnyListenMg.songlistDetail(id: id, page: page, limit: limit)
    default: throw ALSourceError.unsupported(source)
    }
  }

  // MARK: 排行榜（topSongs*：对标 any-listen 榜单浏览链路）

  /// 榜单目录（topSongs → TopSongsItem[]：id/name/pic）
  static func topSongs(source: MusicSource) async -> [ALTopSongsItem] {
    switch source {
    case .kw: return await AnyListenKw.topSongs()
    case .kg: return await AnyListenKg.topSongs()
    case .tx: return await AnyListenTx.topSongs()
    case .wy: return await AnyListenWy.topSongs()
    case .mg: return await AnyListenMg.topSongs()
    default: return []
    }
  }

  /// 榜单期次（topSongsDate → TagItem[]；无期次概念的源返回空）
  static func topSongsDate(source: MusicSource, id: String) async -> [ALTagItem] {
    switch source {
    case .kg: return await AnyListenKg.topSongsDate(id: id)
    default: return []
    }
  }

  /// 榜单详情（topSongsDetail：id + date + page/limit → 歌曲 + 榜单信息）
  static func topSongsDetail(source: MusicSource, id: String, date: String? = nil,
                             page: Int = 1, limit: Int = 100) async throws -> ALTopSongsDetailResult {
    switch source {
    case .kw: return try await AnyListenKw.topSongsDetail(id: id, page: page, limit: limit)
    case .kg: return try await AnyListenKg.topSongsDetail(id: id, date: date, page: page, limit: limit)
    case .tx: return try await AnyListenTx.topSongsDetail(id: id, page: page, limit: limit)
    case .wy: return try await AnyListenWy.topSongsDetail(id: id, page: page, limit: limit)
    case .mg: return try await AnyListenMg.topSongsDetail(id: id, page: page, limit: limit)
    default: throw ALSourceError.unsupported(source)
    }
  }

  // MARK: 单曲资源（musicLyric / musicPic / musicUrl 兜底）

  /// 歌词（musicLyric：全五源；加密格式 kg-krc / tx-QRC 在 LyricCodec 解码）
  static func musicLyric(source: MusicSource, music: MusicInfo) async throws -> ALLyricResult {
    switch source {
    case .kw: return try await AnyListenKw.musicLyric(music)
    case .kg: return try await AnyListenKg.musicLyric(music)
    case .tx: return try await AnyListenTx.musicLyric(music)
    case .wy: return try await AnyListenWy.musicLyric(music)
    case .mg: return try await AnyListenMg.musicLyric(music)
    case .local: throw ALSourceError.unsupported(source)
    }
  }

  /// 封面（musicPic：优先返回已知 picUrl，缺失时按源取官站封面）
  static func musicPic(source: MusicSource, music: MusicInfo) async -> String? {
    if let u = music.picUrl, !u.isEmpty { return u }
    switch source {
    case .kw: return await AnyListenKw.musicPic(music)
    case .kg: return await AnyListenKg.musicPic(music)
    case .tx: return await AnyListenTx.musicPic(music)
    case .wy: return await AnyListenWy.musicPic(music)
    case .mg: return await AnyListenMg.musicPic(music)
    default: return nil
    }
  }

  /// 播放直链兜底（musicUrl：与 GD音乐台同源的 types=url + br 降级链）。
  /// 主路径仍是自定义源脚本（PlayerStore 优先级不变）；本兜底仅在无自定义源/脚本失败时兜住。
  static func musicUrl(source: MusicSource, music: MusicInfo, quality: MusicQuality?) async -> ALMusicUrlInfo? {
    let chain = ALQualityBridge.degradeChain(from: quality)
    switch source {
    case .kw: return await AnyListenKw.musicUrl(music, chain: chain)
    case .wy: return await AnyListenWy.musicUrl(music, chain: chain)
    case .tx: return await AnyListenTx.musicUrl(music, chain: chain)
    case .kg, .mg, .local: return nil // kg/mg 直链依赖自定义源（对标 any-listen 由 LX 源脚本提供）
    }
  }
}

/// any-listen 风格的错误（extension 抛错 → 宿主 toast；这里映射为 LocalizedError）
enum ALSourceError: LocalizedError {
  case unsupported(MusicSource)
  case invalidResponse(String)

  var errorDescription: String? {
    switch self {
    case .unsupported(let s): return "源 \(s.rawValue) 不支持该操作"
    case .invalidResponse(let m): return "解析失败：\(m)"
    }
  }
}

// MARK: - 解析层专用 HTTP（补齐 iMusicHttp 缺的原始字节/查询串能力；JSON 部分复用 iMusicHttp）

enum ALHttp {
  /// GET 原始字节（歌词/封面等二进制响应；kw lrcx、kg krc 用）
  static func getRaw(_ urlString: String, headers: [String: String] = [:],
                     timeout: TimeInterval = 15) async throws -> (data: Data, response: HTTPURLResponse) {
    var req = URLRequest(url: URL(string: urlString)!, timeoutInterval: timeout)
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
      throw ALSourceError.invalidResponse("非 HTTP 响应")
    }
    return (data, http)
  }

  /// GET JSON（带查询串构建：参数自动 percentEncode；kg 带 <!--KG_TAG_RES_START--> 包裹时自动剥离）
  static func getJSON(_ urlString: String, headers: [String: String] = [:],
                      timeout: TimeInterval = 15) async throws -> Any {
    let (data, _) = try await getRaw(urlString, headers: headers, timeout: timeout)
    var body = data
    let text = String(data: data, encoding: .utf8) ?? ""
    // kg 的部分接口在 JSON 外包 <!--KG_TAG_RES_START-->...<!--KG_TAG_RES_END--> 注释
    if let s = text.range(of: "KG_TAG_RES_START"), let e = text.range(of: "KG_TAG_RES_END", range: s.upperBound..<text.endIndex) {
      body = Data(text[s.upperBound..<e.lowerBound].utf8)
    }
    return try JSONSerialization.jsonObject(with: body)
  }

  static func postJSON(_ urlString: String, json: [String: Any],
                       headers: [String: String] = [:],
                       timeout: TimeInterval = 15) async throws -> Any {
    var req = URLRequest(url: URL(string: urlString)!, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = try JSONSerialization.data(withJSONObject: json)
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONSerialization.jsonObject(with: data)
  }

  /// query string 构建（保持插入顺序，值统一 percentEncode）
  static func query(_ params: [(String, String?)]) -> String {
    var out: [String] = []
    for (k, v) in params {
      guard let v, !v.isEmpty else { continue }
      out.append("\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
    }
    return out.joined(separator: "&")
  }

  /// JSON 取值小工具（宽容类型转换：Int/Double/String 互通）
  static func int(_ v: Any?) -> Int? {
    if let n = v as? Int { return n }
    if let n = v as? NSNumber { return n.intValue }
    if let n = v as? Double { return Int(n) }
    if let s = v as? String { return Int(s) }
    return nil
  }

  static func double(_ v: Any?) -> Double? {
    if let n = v as? Double { return n }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
  }

  static func str(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    if let n = v as? Int { return "\(n)" }
    return v != nil ? "\(v!)" : ""
  }

  static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
  static func arr(_ v: Any?) -> [[String: Any]]? { v as? [[String: Any]] }
}

// MARK: - GD音乐台兜底（与 any-listen 官方 GD音乐台扩展同源的直链/歌词兜底通道）
//
// any-listen 生态里 kw/wy/tx 的「可播直链 + 部分歌词」由 GD音乐台扩展提供
// （music-api.gdstudio.xyz，请求头/降级链/错误语义复刻其 src/index.ts）。
// 本层仅在「无自定义源或自定义源失败」时按同款逻辑兜底；kg/mg GD 不提供，
// 仍走自定义源（即 any-listen 的 lx-api-source-loader 同样定位）。

enum AnyListenGD {
  /// 与 gdstudio 扩展一致的 API 入口与请求头
  static let api = "https://music-api.gdstudio.xyz/api.php"

  static func headers() -> [String: String] {
    ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
     "X-Requested-With": "XMLHttpRequest",
     "Referer": "https://music.gdstudio.org/"]
  }

  private static func sourceName(_ source: MusicSource) -> String? {
    switch source {
    case .wy: return "netease"
    case .tx: return "tencent"
    case .kw: return "kuwo"
    default: return nil
    }
  }

  /// types=url：按 gdstudio musicUrl 的 br 降级链逐档尝试（999→740→320→128）
  static func url(source: MusicSource, musicId: String, chain: [Int]) async -> ALMusicUrlInfo? {
    guard let src = sourceName(source) else { return nil }
    for br in chain {
      guard let json = try? await ALHttp.getJSON(
        "\(api)?types=url&source=\(src)&id=\(musicId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&br=\(br)",
        headers: headers()) as? [String: Any],
        let u = json["url"] as? String, u.hasPrefix("http") else { continue }
      let actualBr = ALHttp.int(json["br"]) ?? br
      return ALMusicUrlInfo(url: u, quality: ALQualityBridge.fromBr(actualBr))
    }
    return nil
  }

  /// types=lyric（kw 歌词兜底；GD 当前对 kuwo 大多为直连失败时才有用）
  static func lyric(source: MusicSource, musicId: String) async -> LyricInfo? {
    guard let src = sourceName(source),
          let json = try? await ALHttp.getJSON(
            "\(api)?types=lyric&source=\(src)&id=\(musicId)", headers: headers()) as? [String: Any],
          let lyric = json["lyric"] as? String, !lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    let tlyric = (json["tlyric"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return LyricInfo(lyric: lyric, tlyric: (tlyric?.isEmpty == true) ? nil : tlyric, rlyric: nil, lxlyric: nil)
  }

  /// types=pic（有 pic_id 的场景兜底；iMusic 暂用直连封面，此接口备用）
  static func pic(source: MusicSource, picId: String, size: Int = 500) async -> String? {
    guard let src = sourceName(source),
          let json = try? await ALHttp.getJSON(
            "\(api)?types=pic&source=\(src)&id=\(picId)&size=\(size)", headers: headers()) as? [String: Any],
          let u = json["url"] as? String, u.hasPrefix("http") else { return nil }
    return u
  }
}
