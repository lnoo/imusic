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

/// Resource.MusicCommentItem（歌曲评论条目，对标 any-listen resource.d.ts）
struct ALMusicCommentItem: Hashable, Sendable {
  var id: String
  var userId: String?
  var userName: String
  var text: String
  var time: Int?
  var images: [String]?
  var location: String?
  var avatar: String?
  var likedCount: Int?
  var skipPage: Bool?
  var replyTotal: Int?
  var reply: [ALMusicCommentItem]?
  var replySkipPage: Bool?
}

/// IPCExtension.MusicCommentResult
struct ALMusicCommentResult {
  var list: [ALMusicCommentItem]
  var total: Int
  var limit: Int
  var page: Int
}

// MARK: - any-listen 归一化工具（复刻 gdstudio 源扩展的 buildMusicInfo/格式化）

/// 与 any-listen Music.Quality ↔ GD br 档位一一对应（gdstudio 源扩展 qualityToBr/brToQuality）
enum ALQualityBridge {
  static func toBr(_ quality: MusicQuality) -> Int {
    switch quality {
    case .q128k: return 128
    case .q192k: return 192
    case .q320k: return 320
    case .flac: return 740
    case .flac24bit, .wav, .dolby, .master: return 999
    }
  }

  static func fromBr(_ br: Int) -> MusicQuality {
    if br >= 999 { return .flac24bit }
    if br >= 740 { return .flac }
    if br >= 320 { return .q320k }
    if br >= 192 { return .q192k }
    return .q128k
  }

  /// gdstudio buildQualitysFromBr：从实际可用 br 生成「该档及以下全部音质」声明
  static func qualitys(fromBr br: Int) -> [MusicQualityType] {
    var qs: [MusicQualityType] = [.init(type: .q128k, size: nil)]
    if br >= 192 { qs.append(.init(type: .q192k, size: nil)) }
    if br >= 320 { qs.append(.init(type: .q320k, size: nil)) }
    if br >= 740 { qs.append(.init(type: .flac, size: nil)) }
    if br >= 999 { qs.append(.init(type: .flac24bit, size: nil)) }
    return qs
  }

  /// 播放降级链（gdstudio musicUrl：从用户偏好档及以下逐档尝试）
  static func degradeChain(from quality: MusicQuality?) -> [Int] {
    let all = [999, 740, 320, 192, 128]
    guard let q = quality else { return all }
    let preferred = toBr(q)
    return all.filter { $0 <= preferred }
  }
}

/// 对齐 extensions/online-metadata 的共享格式化工具：
/// src/shared/common.ts (sizeFormate/formatPlayTime/dateFormat)
/// src/shared/utils.ts (formatPlayCount/decodeName/deduplicationList)
/// src/onlineResource/shared.ts (formatSingerName)
enum ALFormat {
  private static func number(_ v: Any?) -> Double? {
    if let n = v as? Double { return n }
    if let n = v as? Int { return Double(n) }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
  }

  /// sizeFormate：`0 B` / `3.56 MB`，单位 B/KB/MB/GB/TB（对照 shared/common.ts）
  static func sizeFormate(_ bytes: Any?) -> String {
    guard let b = number(bytes), b > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    let idx = min(max(Int(floor(log(b) / log(1024))), 0), units.count - 1)
    return String(format: "%.2f \(units[idx])", b / pow(1024, Double(idx)))
  }

  /// formatPlayTime：0 → `--/--`，其余零填充 mm:ss（对照 shared/common.ts）
  static func playTime(_ seconds: Any?) -> String {
    let s = max(0, Int(number(seconds) ?? 0))
    let m = s / 60, sec = s % 60
    if m == 0 && sec == 0 { return "--/--" }
    return String(format: "%02d:%02d", m, sec)
  }

  /// formatPlayCount：严格 `>` 阈值，Math.trunc(num/10000000)/10（对照 shared/utils.ts）
  static func playCount(_ n: Any?) -> String {
    let v = Int(number(n) ?? 0)
    if v > 100_000_000 { return "\(fmt(Double(v) / 10_000_000 / 10))亿" }
    if v > 10_000 { return "\(fmt(Double(v) / 1000 / 10))万" }
    return "\(v)"
  }

  private static func fmt(_ d: Double) -> String {
    String(format: "%g", d)
  }

  /// decodeName（he.decode）：命名实体 + 十进制/十六进制数字实体
  static func decodeName(_ s: String?) -> String {
    guard var out = s, !out.isEmpty else { return "" }
    let named: [String: String] = [
      "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
      "&nbsp;": " ", "&ensp;": " ", "&emsp;": " ", "&copy;": "©", "&reg;": "®",
      "&trade;": "™", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
      "&laquo;": "«", "&raquo;": "»", "&times;": "×", "&divide;": "÷"
    ]
    for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
    // &#123; / &#x1F600;
    if let re = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
      let ns = out as NSString
      let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed()
      for m in matches {
        guard let r = Range(m.range(at: 1), in: out) else { continue }
        let raw = String(out[r])
        let cp: Int32?
        if raw.hasPrefix("x") || raw.hasPrefix("X") {
          cp = Int32(String(raw.dropFirst()), radix: 16)
        } else { cp = Int32(raw) }
        if let cp, cp >= 0, let scalar = UnicodeScalar(UInt32(cp)) {
          out.replaceSubrange(r, with: String(Character(scalar)))
        }
      }
    }
    return out
  }

  /// formatSingerName：数组取名后 join('、')，最后统一 decodeName
  static func singerName(_ arr: Any?, key: String = "name") -> String {
    var names: [String] = []
    if let list = arr as? [Any] {
      for item in list {
        guard let d = item as? [String: Any], let name = d[key] else { continue }
        names.append("\(name)")
      }
    } else if let d = arr as? [String: Any], let name = d[key] {
      names.append("\(name)")
    } else if let s = arr {
      names.append("\(s)")
    }
    return decodeName(names.filter { !$0.isEmpty }.joined(separator: "、"))
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
  /// kw/tx/wy 走原生解析，失败/为空时回退 GD音乐台搜索（对标 gdstudio musicSearch 兜底）
  static func musicSearch(source: MusicSource, name: String, artist: String? = nil,
                          albumName: String? = nil, page: Int = 1, limit: Int = 30) async throws -> ALListResult<MusicInfo> {
    // 对齐 online-metadata/src/onlineResource/index.ts:23（`${name} ${artist} ${albumName}`.trim()）
    let kw = [name, artist, albumName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    switch source {
    case .kw:
      return try await Self.nativeOrGD(.kw, name: kw, artist: nil) { try await AnyListenKw.musicSearch(keyword: kw, page: page, limit: limit) }
    case .kg:
      return try await AnyListenKg.musicSearch(keyword: kw, page: page, limit: limit)
    case .tx:
      return try await Self.nativeOrGD(.tx, name: name, artist: artist) { try await AnyListenTx.musicSearch(keyword: name, page: page, limit: limit) }
    case .wy:
      return try await Self.nativeOrGD(.wy, name: name, artist: artist) { try await AnyListenWy.musicSearch(keyword: kw, page: page, limit: limit) }
    case .mg:
      return try await AnyListenMg.musicSearch(keyword: kw, page: page, limit: limit)
    case .gdNetease, .gdKuwo, .gdTencent, .gdJoox, .gdTidal, .gdQobuz,
         .gdBilibili, .gdApple, .gdYtmusic, .gdSpotify:
      guard let raw = ALGdResourceIds.toGdSource(source.rawValue) else {
        throw ALSourceError.invalidResponse("GD音乐台不支持该源搜索")
      }
      let result = try await ALGdSearch.search(source: raw, name: kw, artist: artist,
                                                page: page, limit: limit)
      // 搜索结果绑定到用户选中的 gd-* 平台（同时决定 gd:v1: 身份）
      let list = result.list.map { item -> MusicInfo in
        var copy = item; copy.source = source; return copy
      }
      return ALListResult(list: list, total: result.total, page: page, limit: limit)
    case .local: throw ALSourceError.unsupported(source)
    }
  }

  /// 原生优先、GD 兜底：原生抛错或空列表时回退 GD音乐台搜索
  private static func nativeOrGD(_ source: MusicSource, name: String, artist: String?,
                                 native: () async throws -> ALListResult<MusicInfo>) async throws -> ALListResult<MusicInfo> {
    if let r = try? await native(), !r.list.isEmpty { return r }
    return try await AnyListenGD.search(source: source, name: name, artist: artist)
  }

  /// 热搜词（hotSearch → string[]；全五源覆盖 online-metadata，失败回退固定推荐词）
  static func hotSearch(source: MusicSource) async -> [String] {
    switch source {
    case .kw: return (try? await AnyListenKw.hotSearch()) ?? Self.defaultHotWords
    case .kg: return (try? await AnyListenKg.hotSearch()) ?? Self.defaultHotWords
    case .tx: return (try? await AnyListenTx.hotSearch()) ?? Self.defaultHotWords
    case .wy: return (try? await AnyListenWy.hotSearch()) ?? Self.defaultHotWords
    case .mg: return (try? await AnyListenMg.hotSearch()) ?? Self.defaultHotWords
    default: return Self.defaultHotWords
    }
  }

  /// 搜索提示（tipSearch → string[]；全五源覆盖 online-metadata）
  static func tipSearch(source: MusicSource, keyword: String) async -> [String] {
    switch source {
    case .kw: return (try? await AnyListenKw.tipSearch(keyword: keyword)) ?? []
    case .tx: return (try? await AnyListenTx.tipSearch(keyword: keyword)) ?? []
    case .kg: return (try? await AnyListenKg.tipSearch(keyword: keyword)) ?? []
    case .wy: return (try? await ALExtraSearch.tipSearch(source: source, keyword: keyword)) ?? []
    case .mg: return (try? await AnyListenMg.tipSearch(keyword: keyword)) ?? []
    default: return []
    }
  }

  /// 歌曲评论（musicComment → MusicCommentResult；全五源覆盖 online-metadata）
  static func musicComment(source: MusicSource, music: MusicInfo, type: String,
                           page: Int, limit: Int = 20) async throws -> ALMusicCommentResult {
    switch source {
    case .mg: return try await AnyListenMg.musicComment(music: music, type: type, page: page, limit: limit)
    case .kw: return try await ALCommentKw.comment(music: music, type: type, page: page, limit: limit)
    case .kg: return try await ALCommentKg.comment(music: music, type: type, page: page, limit: limit)
    case .tx: return try await ALCommentTx.comment(music: music, type: type, page: page, limit: limit)
    case .wy: return try await ALCommentWy.comment(music: music, type: type, page: page, limit: limit)
    default: throw ALSourceError.unsupported(source)
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
    case .tx: return try await AnyListenTx.topSongsDetail(id: id, date: date, page: page, limit: limit)
    case .wy: return try await AnyListenWy.topSongsDetail(id: id, page: page, limit: limit)
    case .mg: return try await AnyListenMg.topSongsDetail(id: id, page: page, limit: limit)
    default: throw ALSourceError.unsupported(source)
    }
  }

  // MARK: 单曲资源（musicLyric / musicPic / musicUrl 兜底）

  /// 歌词（musicLyric：全五源；加密格式 kg-krc / tx-QRC 在 LyricCodec 解码）
  static func musicLyric(source: MusicSource, music: MusicInfo) async throws -> ALLyricResult {
    let base: LyricInfo
    switch source {
    case .kw: base = try await AnyListenKw.musicLyric(music)
    case .kg: base = try await AnyListenKg.musicLyric(music)
    case .tx: base = try await AnyListenTx.musicLyric(music)
    case .wy: base = try await AnyListenWy.musicLyric(music)
    case .mg: base = try await AnyListenMg.musicLyric(music)
    case .gdNetease, .gdKuwo, .gdTencent, .gdJoox, .gdTidal, .gdQobuz,
         .gdBilibili, .gdApple, .gdYtmusic, .gdSpotify:
      base = await AnyListenGD.lyric(source: source, music: music) ?? LyricInfo(lyric: "")
    case .local: throw ALSourceError.unsupported(source)
    }
    // 扩展的逐字歌词（YRC/MRC → awlyric/lxlyric）；失败时保留基础歌词
    return await ALWordLyric.enrich(base, from: source, music: music)
  }

  /// 封面（musicPic：优先返回已知 picUrl，缺失时按源取官站封面）
  static func musicPic(source: MusicSource, music: MusicInfo) async -> String? {
    if let u = music.picUrl, !u.isEmpty { return u }
    switch source {
    case .kw: return await AnyListenKw.musicPic(music)
    case .kg: return await AnyListenKg.musicPic(music)
    case .tx: return await AnyListenTx.musicPic(music)
    case .wy: return await AnyListenWy.musicPic(music)
    case .mg:
      if let pic = await ALMgDetail.pic(for: music) { return pic }
      return await AnyListenMg.musicPic(music)
    case .gdNetease, .gdKuwo, .gdTencent, .gdJoox, .gdTidal, .gdQobuz,
         .gdBilibili, .gdApple, .gdYtmusic, .gdSpotify:
      return await AnyListenGD.pic(source: source, music: music, size: 500)
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
    case .gdNetease, .gdKuwo, .gdTencent, .gdJoox, .gdTidal, .gdQobuz,
         .gdBilibili, .gdApple, .gdYtmusic, .gdSpotify:
      return await AnyListenGD.url(source: source, musicId: music.songmid, chain: chain)
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
                     timeout: TimeInterval = 15, requireOK: Bool = false) async throws -> (data: Data, response: HTTPURLResponse) {
    var req = URLRequest(url: URL(string: urlString)!, timeoutInterval: timeout)
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
      throw ALSourceError.invalidResponse("非 HTTP 响应")
    }
    // 扩展各动作普遍校验 statusCode !== 200；requireOK 控制是否强制校验
    if requireOK, http.statusCode != 200 {
      throw ALSourceError.invalidResponse("HTTP \(http.statusCode)")
    }
    return (data, http)
  }

  /// GET JSON（带查询串构建：参数自动 percentEncode；kg 带 <!--KG_TAG_RES_START--> 包裹时自动剥离）
  static func getJSON(_ urlString: String, headers: [String: String] = [:],
                      timeout: TimeInterval = 15, requireOK: Bool = false) async throws -> Any {
    let (data, _) = try await getRaw(urlString, headers: headers, timeout: timeout, requireOK: requireOK)
    var body = data
    let text = String(data: data, encoding: .utf8) ?? ""
    // kg 的部分接口在 JSON 外包 <!--KG_TAG_RES_START-->...<!--KG_TAG_RES_END--> 注释
    if let s = text.range(of: "KG_TAG_RES_START"), let e = text.range(of: "KG_TAG_RES_END", range: s.upperBound..<text.endIndex) {
      body = Data(text[s.upperBound..<e.lowerBound].utf8)
    }
    do {
      return try JSONSerialization.jsonObject(with: body)
    } catch {
      // 部分接口（如 QQ 歌单搜索）混入 GBK 字节，UTF-8 直解失败；
      // 与扩展 request 层的 dataConverter 对齐，转码后重试一次。
      let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
      if let decoded = String(data: body, encoding: gbk),
         let utf8 = decoded.data(using: .utf8),
         utf8 != body {
        return try JSONSerialization.jsonObject(with: utf8)
      }
      // 最后兜底：无损 UTF-8 解码（非法字节替换为 U+FFFD），兼容混入 GBK 片段的响应
      let lossy = String(decoding: body, as: UTF8.self)
      if lossy.utf8.count != body.count || lossy.unicodeScalars.contains(where: { $0.value == 0xFFFD }) {
        return try JSONSerialization.jsonObject(with: Data(lossy.utf8))
      }
      throw error
    }
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

  /// 统一请求入口：组织源经签名服务器（对齐 gdstudio apiCallOrg），其余走主 API
  private static func request(types: String, source: String,
                              params: [String: String] = [:]) async throws -> Any? {
    if ALGdSign.isOrgSource(source) {
      return try await ALGdSign.call(types: types, source: source, extra: params)
    }
    let q = params.map { k, v in
      "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)"
    }.joined(separator: "&")
    return try await ALHttp.getJSON("\(api)?types=\(types)&source=\(source)&\(q)", headers: headers())
  }

  private static func sourceName(_ source: MusicSource) -> String? {
    switch source {
    case .wy, .gdNetease: return "netease"
    case .tx, .gdTencent: return "tencent"
    case .kw, .gdKuwo: return "kuwo"
    case .gdJoox: return "joox"
    case .gdTidal: return "tidal"
    case .gdQobuz: return "qobuz"
    case .gdBilibili: return "bilibili"
    case .gdApple: return "apple"
    case .gdYtmusic: return "ytmusic"
    case .gdSpotify: return "spotify"
    default: return nil
    }
  }

  /// types=url：按 gdstudio musicUrl 的 br 降级链逐档尝试（999→740→320→128）
  static func url(source: MusicSource, musicId: String, chain: [Int]) async -> ALMusicUrlInfo? {
    guard let src = sourceName(source) else { return nil }
    for br in chain {
      guard let json = try? await request(types: "url", source: src,
                                          params: ["id": musicId, "br": "\(br)"]) as? [String: Any],
            let u = json["url"] as? String, u.hasPrefix("http") else { continue }
      let actualBr = ALHttp.int(json["br"]) ?? br
      return ALMusicUrlInfo(url: u, quality: ALQualityBridge.fromBr(actualBr))
    }
    return nil
  }

  /// types=lyric（GD音乐台歌词；歌词 id 经 resource id 缓存解析）
  static func lyric(source: MusicSource, music: MusicInfo) async -> LyricInfo? {
    guard let src = sourceName(source),
          let ids = await ALGdResourceIds.ensure(source: src, musicInfo: music, requiredType: .lyric),
          let lyricId = ids.lyricId else { return nil }
    guard let json = try? await request(types: "lyric", source: src, params: ["id": lyricId]) as? [String: Any],
          let lyric = json["lyric"] as? String, !lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    let tlyric = (json["tlyric"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return LyricInfo(lyric: lyric, tlyric: (tlyric?.isEmpty == true) ? nil : tlyric, rlyric: nil, lxlyric: nil)
  }

  /// types=pic（GD音乐台封面；封面 id 经 resource id 缓存解析）
  static func pic(source: MusicSource, music: MusicInfo, size: Int = 500) async -> String? {
    guard let src = sourceName(source),
          let ids = await ALGdResourceIds.ensure(source: src, musicInfo: music, requiredType: .pic),
          let picId = ids.picId else { return nil }
    guard let json = try? await request(types: "pic", source: src,
                                        params: ["id": picId, "size": "\(size)"]) as? [String: Any],
          let u = json["url"] as? String, u.hasPrefix("http") else { return nil }
    return u
  }

  /// types=search（GD音乐台主 API 搜索；原生迁移自 gdstudio src/index.ts musicSearch + buildMusicInfo）
  /// sourceName 返回 nil 的源（kg/mg/local）不支持 GD 搜索 → 返回空列表。
  static func search(source: MusicSource, name: String, artist: String? = nil,
                     page: Int = 1, limit: Int = 20) async throws -> ALListResult<MusicInfo> {
    guard let src = sourceName(source) else {
      throw ALSourceError.invalidResponse("GD音乐台不支持该源搜索")
    }
    // gdstudio: fetchCount = limit * 3，按 apiPage 请求，按 id 去重后切片出本页
    let fetchCount = min(limit * 3, 50)
    let queryName = (artist?.isEmpty == false) ? "\(name) \(artist!)" : name
    guard let json = try? await request(types: "search", source: src,
                                        params: ["count": "\(fetchCount)", "pages": "\(page)", "name": queryName])
    else { return ALListResult(list: [], total: 0, page: page, limit: limit) }
    let rawList = json as? [[String: Any]] ?? []
    // 去重（按 id）
    var seen = Set<String>()
    var all: [MusicInfo] = []
    for item in rawList {
      let gid = ALHttp.str(item["id"])
      guard !gid.isEmpty, seen.insert(gid).inserted else { continue }
      all.append(mapSearchItem(item, source: source))
    }
    // 切片出当前页（gdstudio pagination.getPage(page, limit)）
    let start = (page - 1) * limit
    let list = start < all.count ? Array(all[start..<min(all.count, start + limit)]) : []
    return ALListResult(list: list, total: all.count, page: page, limit: limit)
  }

  /// gdstudio buildMusicInfo：GD 原始条目 → MusicInfo
  private static func mapSearchItem(_ item: [String: Any], source: MusicSource) -> MusicInfo {
    let src = sourceName(source) ?? source.rawValue
    let gid = ALHttp.str(item["id"])
    var interval: String? = nil
    let dur = ALHttp.double(item["duration"]) ?? ALHttp.double(item["interval"]) ?? 0
    if dur > 0 { interval = ALNormalize.formatInterval(Int(dur)) }
    var extra: [String: String] = ["_gdResourceVersion": "1"]
    if let picId = item["pic_id"] { extra["_picId"] = ALHttp.str(picId) }
    if let lyricId = item["lyric_id"] { extra["_lyricId"] = ALHttp.str(lyricId) }
    let br = ALHttp.int(item["br"]) ?? ALHttp.int(item["maxbr"]) ?? 128
    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(item["name"])),
      singer: ALNormalize.parseArtist(item["artist"]),
      source: ALGdResourceIds.toGdSource(source.rawValue) != nil ? source : musicSource(fromGd: src),
      songmid: gid,
      albumName: ALFormat.decodeName(ALHttp.str(item["album"])),
      interval: interval,
      qualitys: ALQualityBridge.qualitys(fromBr: br),
      picUrl: nil,
      extra: extra)
  }

  /// GD 源名 → iMusic MusicSource（sourceName 的逆映射；未知源回退本地占位）
  private static func musicSource(fromGd s: String) -> MusicSource {
    switch s {
    case "netease": return .wy
    case "tencent": return .tx
    case "kuwo": return .kw
    case "joox": return .gdJoox
    case "tidal": return .gdTidal
    case "qobuz": return .gdQobuz
    case "bilibili": return .gdBilibili
    case "apple": return .gdApple
    case "ytmusic": return .gdYtmusic
    case "spotify": return .gdSpotify
    default: return .local
    }
  }
}
