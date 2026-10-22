import Foundation

// MARK: - 主页榜单目录（源 -> 榜单两级展开的唯一真相源）
//
// 榜单目录保持不变（UI 同构）：id 形如 "kw__16"（source__榜单key），与主页缓存 key 同构。
// key 的含义按源而定：kw=bangid，kg=rankid，tx=topid，wy=歌单id，mg=columnId。
// 实际抓取统一走 any-listen 解析层（AnyListenResource.topSongsDetail → 各源实现）：
//   kw kbangserver / kg rank/song / tx ToplistInfoServer / wy playlist detail / mg querycontentbyId

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
    // 酷狗（rankid 实测有数；全量榜单目录另见 AnyListenKg.topSongs）
    HomeBoard(sourceId: "kg", key: "8888", name: "TOP500", category: "推荐"),
    HomeBoard(sourceId: "kg", key: "6666", name: "飙升榜", category: "飙升"),
    // QQ（topid；全量榜单目录另见 AnyListenTx.topSongs）
    HomeBoard(sourceId: "tx", key: "26", name: "热歌榜", category: "推荐"),
    HomeBoard(sourceId: "tx", key: "4", name: "流行指数榜", category: "推荐"),
    HomeBoard(sourceId: "tx", key: "27", name: "新歌榜", category: "新歌"),
    HomeBoard(sourceId: "tx", key: "28", name: "网络歌曲榜", category: "场景"),
    // 网易（榜单 = 官方歌单；与 AnyListenWy.boards 同源）
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

/// 按目录抓取单榜：分发到 any-listen 解析层（topSongsDetail）
enum HomeBoardFetcher {
  static func fetch(_ board: HomeBoard, limit: Int = 10) async throws -> [MusicInfo] {
    guard let source = MusicSource(rawValue: board.sourceId) else {
      throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "未知榜单源 \(board.sourceId)"])
    }
    let r = try await AnyListenResource.topSongsDetail(source: source, id: board.key, limit: limit)
    return r.list
  }
}
