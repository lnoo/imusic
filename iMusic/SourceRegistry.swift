import Foundation

// MARK: - 源能力注册表（对标 any-listen ResourceAction 契约的宿主侧）
// 加新源只需：MusicSource 加一个 case + buildBuiltins 加一行 register，
// 搜索/榜单/歌词/封面/设置页/主页全部自动出现，不再满屏 switch。
//
// 各闭包均委托 any-listen 解析层（AnyListenResource → AnyListen{Kw,Kg,Tx,Wy,Mg}）：
//   search  musicSearch | board  topSongsDetail（固定默认榜，主页目录另见 HomeBoards）
//   lyric   musicLyric  | pic    musicPic     | fallbackUrl  musicUrl（GD音乐台同源兜底）

/// 单源能力。nil 表示该源不支持该能力（对标上游按模块有无判断，如 `sm.musicSearch`）。
struct SourceCapability: Sendable {
  var id: String // MusicSource.rawValue
  var displayName: String // "酷我"
  var systemImage: String // SF Symbol
  var sortOrder: Int
  /// 内置模式音质支持（对标 api-source-info supportQualitys；自定义源生效时以 engine.qualitys 为准）
  var supportQualitys: [MusicQuality]
  var search: (@Sendable (String, Int, Int) async throws -> (items: [MusicInfo], total: Int))?
  var board: (@Sendable (Int) async throws -> [MusicInfo])?
  var lyric: (@Sendable (MusicInfo) async throws -> LyricInfo?)?
  var pic: (@Sendable (MusicInfo) async -> String?)?
  /// 播放直链兜底（对标 any-listen musicUrl；主路径仍是 LX 自定义源脚本）
  var fallbackUrl: (@Sendable (MusicInfo, MusicQuality) async -> ALMusicUrlInfo?)?
}

enum SourceRegistry {
  /// 内置源表（一次性不可变构建，天然线程安全；加新源只改 buildBuiltins 一处）
  static let all: [SourceCapability] = buildBuiltins()

  /// 解析层搜索闭包适配（AnyListenResource.musicSearch → 注册表签名）
  private static func searchVia(_ source: MusicSource) -> @Sendable (String, Int, Int) async throws -> (items: [MusicInfo], total: Int) {
    { keyword, page, limit in
      let r = try await AnyListenResource.musicSearch(source: source, name: keyword, page: page, limit: limit)
      return (r.list, r.total)
    }
  }

  /// 默认榜闭包（各源热歌榜；主页多榜目录见 HomeBoards）
  private static func boardVia(_ source: MusicSource, defaultBoardId: String) -> @Sendable (Int) async throws -> [MusicInfo] {
    { limit in
      let r = try await AnyListenResource.topSongsDetail(source: source, id: defaultBoardId, limit: limit)
      return r.list
    }
  }

  /// GD音乐台平台的统一能力构造（对标 gdstudio 的 gd-* 资源贡献）
  private static func gdCapability(id: String, name: String, image: String, order: Int,
                                   source: MusicSource) -> SourceCapability {
    SourceCapability(
      id: id, displayName: name, systemImage: image, sortOrder: order,
      supportQualitys: MusicQuality.highToLow,
      search: searchVia(source),
      board: nil,
      lyric: { try await AnyListenResource.musicLyric(source: source, music: $0) },
      pic: { await AnyListenResource.musicPic(source: source, music: $0) },
      fallbackUrl: { music, quality in
        await AnyListenResource.musicUrl(source: source, music: music, quality: quality)
      }
    )
  }

  private static func buildBuiltins() -> [SourceCapability] {
    [
      SourceCapability(
        id: "kw", displayName: "酷我", systemImage: "music.note", sortOrder: 0,
        supportQualitys: [.q128k], // www playUrl 兜底仅 128k；更高档位走自定义源
        search: searchVia(.kw),
        board: boardVia(.kw, defaultBoardId: "16"),
        lyric: { try await AnyListenResource.musicLyric(source: .kw, music: $0) },
        pic: { await AnyListenResource.musicPic(source: .kw, music: $0) },
        fallbackUrl: { music, quality in
          await AnyListenResource.musicUrl(source: .kw, music: music, quality: quality)
        }
      ),
      SourceCapability(
        id: "kg", displayName: "酷狗", systemImage: "music.note.list", sortOrder: 1,
        supportQualitys: MusicQuality.highToLow,
        search: searchVia(.kg),
        board: boardVia(.kg, defaultBoardId: "8888"),
        lyric: { try await AnyListenResource.musicLyric(source: .kg, music: $0) },
        pic: { await AnyListenResource.musicPic(source: .kg, music: $0) },
        fallbackUrl: nil // kg 无公开直链（对标 any-listen：由 LX 自定义源提供）
      ),
      SourceCapability(
        id: "tx", displayName: "QQ音乐", systemImage: "play.circle", sortOrder: 2,
        supportQualitys: MusicQuality.highToLow,
        search: searchVia(.tx),
        board: boardVia(.tx, defaultBoardId: "26"),
        lyric: { try await AnyListenResource.musicLyric(source: .tx, music: $0) },
        pic: { await AnyListenResource.musicPic(source: .tx, music: $0) },
        fallbackUrl: { music, quality in
          await AnyListenResource.musicUrl(source: .tx, music: music, quality: quality) // GD音乐台同源兜底
        }
      ),
      SourceCapability(
        id: "wy", displayName: "网易云", systemImage: "cloud", sortOrder: 3,
        supportQualitys: MusicQuality.highToLow,
        search: searchVia(.wy),
        board: boardVia(.wy, defaultBoardId: "3778678"),
        lyric: { try await AnyListenResource.musicLyric(source: .wy, music: $0) },
        pic: { await AnyListenResource.musicPic(source: .wy, music: $0) },
        fallbackUrl: { music, quality in
          await AnyListenResource.musicUrl(source: .wy, music: music, quality: quality) // GD音乐台同源兜底
        }
      ),
      SourceCapability(
        id: "mg", displayName: "咪咕", systemImage: "radio", sortOrder: 4,
        supportQualitys: MusicQuality.highToLow,
        search: searchVia(.mg),
        board: boardVia(.mg, defaultBoardId: "27186466"),
        lyric: { try await AnyListenResource.musicLyric(source: .mg, music: $0) },
        pic: { await AnyListenResource.musicPic(source: .mg, music: $0) },
        fallbackUrl: nil // mg 无公开直链（对标 any-listen：由 LX 自定义源提供）
      ),
      // GD音乐台扩展提供的额外平台（extensions/gdstudio/src/identity.ts）
      // 对标 gdstudio 的 gd-* 资源：musicSearch / musicUrl / musicPic / musicLyric（无榜单动作）
      gdCapability(id: "gd-netease", name: "网易云音乐·GD", image: "cloud", order: 7, source: .gdNetease),
      gdCapability(id: "gd-kuwo", name: "酷我音乐·GD", image: "music.note", order: 8, source: .gdKuwo),
      gdCapability(id: "gd-tencent", name: "QQ音乐·GD", image: "play.circle", order: 9, source: .gdTencent),
      gdCapability(id: "gd-joox", name: "JOOX", image: "music.note", order: 10, source: .gdJoox),
      gdCapability(id: "gd-tidal", name: "TIDAL", image: "music.note", order: 11, source: .gdTidal),
      gdCapability(id: "gd-qobuz", name: "QOBUZ", image: "music.note", order: 12, source: .gdQobuz),
      gdCapability(id: "gd-bilibili", name: "哔哩哔哩", image: "tv", order: 13, source: .gdBilibili),
      gdCapability(id: "gd-apple", name: "Apple Music", image: "music.note", order: 14, source: .gdApple),
      gdCapability(id: "gd-ytmusic", name: "YouTube Music", image: "play.rectangle", order: 15, source: .gdYtmusic),
      gdCapability(id: "gd-spotify", name: "Spotify", image: "music.note", order: 16, source: .gdSpotify),
      SourceCapability(
        id: "local", displayName: "本地", systemImage: "internaldrive", sortOrder: 99,
        supportQualitys: []
      ),
    ].sorted { $0.sortOrder < $1.sortOrder }
  }

  /// 有搜索能力的源（对标上游 searchMusic 遍历 musicSearch 存在的源）
  static var searchable: [SourceCapability] { all.filter { $0.search != nil } }
  /// 有榜单的源（主页多源榜单 Tab 来源）
  static var withBoard: [SourceCapability] { all.filter { $0.board != nil } }

  static func capability(id: String) -> SourceCapability? {
    all.first { $0.id == id }
  }

  /// 内置模式音质表（对标 musicSdk.supportQuality[apiId]；temp 只有 kw 128k 兜底）
  static var builtinQualityMap: [String: [MusicQuality]] {
    Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.supportQualitys) })
  }
}
