import Foundation

// MARK: - 源能力注册表（对标 musicSdk/index.js sources + 各源 index.js 统一接口）
// 加新源只需：MusicSource 加一个 case + registerBuiltins 加一行 register，
// 搜索/榜单/歌词/封面/设置页/主页全部自动出现，不再满屏 switch。

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
  var fallbackUrl: (@Sendable (String, MusicQuality) -> String?)?
}

enum SourceRegistry {
  /// 内置源表（一次性不可变构建，天然线程安全；加新源只改 buildBuiltins 一处）
  static let all: [SourceCapability] = buildBuiltins()

  private static func buildBuiltins() -> [SourceCapability] {
    [
      SourceCapability(
        id: "kw", displayName: "酷我", systemImage: "music.note", sortOrder: 0,
        supportQualitys: [.q128k],
        search: { keyword, page, limit in
          let r = try await KwSearch.search(keyword: keyword, page: page, limit: limit)
          return (r.items, r.total)
        },
        board: KwBoard.hotSongs,
        lyric: { await OfficialLyric.kw($0) },
        pic: OfficialPic.kwPic,
        fallbackUrl: KwFallback.url
      ),
      SourceCapability(
        id: "kg", displayName: "酷狗", systemImage: "music.note.list", sortOrder: 1,
        supportQualitys: MusicQuality.highToLow,
        search: KgSearch.search,
        board: KgBoard.hotSongs,
        lyric: { await OfficialLyric.kg($0) },
        pic: nil // 搜索/榜单无图，OfficialPic 默认走 song.picUrl（即无）
      ),
      SourceCapability(
        id: "tx", displayName: "QQ音乐", systemImage: "play.circle", sortOrder: 2,
        supportQualitys: MusicQuality.highToLow,
        search: TxSearch.search,
        board: TxBoard.hotSongs,
        lyric: nil, // QRC 加密，MVP 仅走自定义源（对标 tx/lyric.js 注释）
        pic: nil // 搜索自带图，走 song.picUrl
      ),
      SourceCapability(
        id: "wy", displayName: "网易云", systemImage: "cloud", sortOrder: 3,
        supportQualitys: MusicQuality.highToLow,
        search: WySearch.search,
        board: WyBoard.hotSongs,
        lyric: OfficialLyric.wy,
        pic: nil // 搜索自带图
      ),
      SourceCapability(
        id: "mg", displayName: "咪咕", systemImage: "radio", sortOrder: 4,
        supportQualitys: MusicQuality.highToLow,
        search: MgSearch.search,
        board: MgBoard.hotSongs,
        lyric: nil, // MRC 加密，MVP 仅走自定义源
        pic: nil // 搜索自带图
      ),
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
