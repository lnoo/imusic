import Foundation
import Observation

// MARK: - SearchService
// 搜索会话编排层（UI 可观察状态不变）。各源实际解析位于 AnyListen{Kw,Kg,Tx,Wy,Mg}.swift，
// 经 SourceRegistry 闭包接入（对标 any-listen app/modules/resources/musicSearch 的分发方式）。

@Observable @MainActor
final class SearchService {
  var results: [MusicInfo] = []
  var total = 0
  var searching = false
  var error: String?
  var keyword = ""

  /// 搜索会话号：每次发起新搜索 +1，供 UI 判断“新一轮结果已落地”并把列表滚回顶部；
  /// 同时用于丢弃过期的并发结果（晚返回的旧请求不应覆盖新查询）。
  var searchSession = 0

  /// 默认榜单（打开即有歌，不知道搜啥也能直接点）：酷我热歌榜（any-listen topSongs 同源）
  var hot: [MusicInfo] = []
  var hotLoading = false
  var showingHot = true

  static let hotKeywords = ["周杰伦", "林俊杰", "陈奕迅", "薛之谦", "邓紫棋", "陶喆", "王菲", "许嵩"]

  /// TaskGroup 子任务的结果一律用具名 Sendable struct 传递，
  /// 不捕获 self/大 struct（release -O 下曾在此崩溃：
  /// AccumulatingTaskGroup::offer 内 tuple_initializeWithCopy 野指针）。
  private struct BoardSlice: Sendable {
    var id: String
    var items: [MusicInfo]
  }
  private struct SearchJob: Sendable {
    var id: String
    var order: Int
    var search: @Sendable (String, Int, Int) async throws -> (items: [MusicInfo], total: Int)
  }
  private struct SearchSlice: Sendable {
    var id: String
    var order: Int
    var items: [MusicInfo]
  }

  /// 多源聚合（对标 musicSdk/index.js + 各源 search）：默认全源并发，各取前15首
  var multiResults: [(source: MusicSource, items: [MusicInfo])] = []
  var enabledSources: Set<MusicSource> = Set(MusicSource.allCases.filter { $0 != .local })

  func search(keyword: String, page: Int = 1, limit: Int = 30) async {
    guard let fn = SourceRegistry.searchable.first?.search else { return } // 注册表首个可搜索源（历史行为）
    await search(fn, keyword: keyword, page: page, limit: limit)
  }

  /// 发起新一轮搜索的唯一入口：会话号 +1（供结果列表回顶、丢弃过期并发结果）
  /// 然后写入 keyword 并置 searching。发起与结束各改变一次 scrollToken，见 SearchView。
  private func start(keyword: String) -> Bool {
    let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !kw.isEmpty else { return false }
    searchSession += 1
    self.keyword = kw
    searching = true; error = nil; showingHot = false
    return true
  }

  private func search(
    _ fn: @Sendable (String, Int, Int) async throws -> (items: [MusicInfo], total: Int),
    keyword: String,
    page: Int,
    limit: Int
  ) async {
    guard start(keyword: keyword) else { return }
    let session = searchSession
    defer { searching = false }
    do {
      let r = try await fn(keyword, page, limit)
      guard session == searchSession else { return } // 已发起新一轮搜索，丢弃过期结果
      self.results = r.items
      self.total = r.total
      self.showingHot = false
    } catch {
      self.error = error.localizedDescription
    }
  }

  func loadHot() async {
    guard hot.isEmpty, !hotLoading else { return }
    hotLoading = true
    defer { hotLoading = false }
    do {
      // 默认热榜走注册表首个榜单（酷我热歌榜，保持历史行为）
      guard let fn = SourceRegistry.withBoard.first?.board else { return }
      hot = try await fn(30)
      // 不改 showingHot：用户可能已先搜索，避免热榜加载把结果页盖回热榜
    } catch {
      self.error = "热榜加载失败：\(error.localizedDescription)"
    }
  }

  // MARK: - 主页多榜单聚合（目录见 Boards.swift HomeBoards：源 -> 榜单两级展开）
  // key = HomeBoard.id（"kw__16"），与磁盘缓存同构。按源懒加载：主页切到哪个源才拉该源的榜。
  var homeCharts: [String: [MusicInfo]] = [:]
  var homeChartsLoading = false
  var homeChartsError: String?
  /// 当前正在拉取的源（主页只转对应源的菊花，不锁全页）
  var loadingSourceId: String?

  /// 榜单磁盘缓存有效期：榜单天级更新，12 小时内视为新鲜（秒开），过期也展示但前台拉取
  static let homeChartsTTL: TimeInterval = 12 * 3600
  /// 本次榜单数据的更新时间（缓存恢复或网络拉取后设置，UI 展示"X小时前更新"）
  var homeChartsUpdatedAt: Date?

  private struct HomeChartsCache: Codable {
    var updatedAt: Date
    var charts: [String: [MusicInfo]] // key = HomeBoard.id
  }

  private var chartsCacheFile: URL {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("iMusic", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("home_charts_v2.json")
  }

  /// 旧缓存文件（v1：key = 源id）。仅做一次性迁移。
  private var legacyChartsCacheFile: URL {
    chartsCacheFile.deletingLastPathComponent().appendingPathComponent("home_charts.json")
  }

  // MARK: 榜单动态目录（any-listen topSongs 接口；带榜图；kg/tx 有数十张榜）
  /// sourceId -> 动态目录；空/失败时 `boards(for:)` 回退 HomeBoards 静态目录
  var boardCatalog: [String: [HomeBoard]] = [:]
  var boardCatalogLoadingSource: String?
  /// 主页一次预取的榜单数上限（目录可含数十榜，其余卡片点进详情再拉）
  static let homeChartsPrefetchLimit = 8

  /// 当前生效的榜单目录：动态优先，静态兜底
  func boards(for sourceId: String) -> [HomeBoard] {
    if let dyn = boardCatalog[sourceId], !dyn.isEmpty { return dyn }
    return HomeBoards.boards(for: sourceId)
  }

  /// 按 id 查榜（动态 + 静态都查；详情页用）
  func board(id: String) -> HomeBoard? {
    let sourceId = id.split(separator: "__").first.map(String.init) ?? ""
    if let b = boardCatalog[sourceId]?.first(where: { $0.id == id }) { return b }
    return HomeBoards.board(id: id)
  }

  /// 拉取某源的动态榜单目录（成功后主页卡片带封面；失败静默回退静态目录）
  func loadBoardCatalog(for sourceId: String) async {
    guard boardCatalog[sourceId] == nil,
          boardCatalogLoadingSource != sourceId,
          let source = MusicSource(rawValue: sourceId), source != .local else { return }
    boardCatalogLoadingSource = sourceId
    defer { boardCatalogLoadingSource = nil }
    let items = await AnyListenResource.topSongs(source: source)
    guard !items.isEmpty else { return }
    boardCatalog[sourceId] = items.map { HomeBoards.dynamicBoard(sourceId: sourceId, item: $0) }
  }

  /// 该源是否有任何榜单数据（主页切源时决定是否触发网络拉取）
  func hasCharts(for sourceId: String) -> Bool {
    boards(for: sourceId).contains { !(homeCharts[$0.id]?.isEmpty ?? true) }
  }

  /// 同步恢复磁盘缓存（有就展示，保证冷启动秒开）。
  /// - Returns: 缓存是否仍在有效期内
  @discardableResult
  func restoreHomeChartsCache() -> Bool {
    if let data = try? Data(contentsOf: chartsCacheFile),
       let c = try? JSONDecoder().decode(HomeChartsCache.self, from: data) {
      let merged = c.charts.filter { !$0.value.isEmpty }
      if !merged.isEmpty {
        self.homeCharts = merged
        self.homeChartsUpdatedAt = c.updatedAt
        return Date().timeIntervalSince(c.updatedAt) < Self.homeChartsTTL
      }
    }
    // v1 一次性迁移：老 key 是源 id，映射到该源首榜；新榜切源时再拉
    if let data = try? Data(contentsOf: legacyChartsCacheFile),
       let c = try? JSONDecoder().decode(HomeChartsCache.self, from: data) {
      var mapped: [String: [MusicInfo]] = [:]
      for (srcId, items) in c.charts where !items.isEmpty {
        if let def = HomeBoards.boards(for: srcId).first {
          mapped[def.id] = items
        }
      }
      if !mapped.isEmpty {
        self.homeCharts = mapped
        self.homeChartsUpdatedAt = c.updatedAt
        saveHomeChartsCache()
        return Date().timeIntervalSince(c.updatedAt) < Self.homeChartsTTL
      }
    }
    return false
  }

  private func saveHomeChartsCache() {
    let raw = homeCharts.filter { !$0.value.isEmpty }
    guard !raw.isEmpty else { return }
    if let d = try? JSONEncoder().encode(HomeChartsCache(updatedAt: homeChartsUpdatedAt ?? Date(), charts: raw)) {
      try? d.write(to: chartsCacheFile)
    }
  }

  /// 拉取单个源的全部榜单（并发；单榜失败置空，不影响同源其他榜和其他源已有数据）
  func loadHomeCharts(for sourceId: String, limitPerBoard: Int = 10) async {
    guard !homeChartsLoading else { return }
    // 动态目录可含数十张榜：主页只预取前 N 张，其余卡片点进详情再拉
    let boards = Array(boards(for: sourceId).prefix(Self.homeChartsPrefetchLimit))
    guard !boards.isEmpty else { return }
    homeChartsLoading = true
    loadingSourceId = sourceId
    homeChartsError = nil
    defer { homeChartsLoading = false; loadingSourceId = nil }
    let parts = await withTaskGroup(of: BoardSlice.self, returning: [BoardSlice].self) { group in
      for b in boards {
        group.addTask {
          do {
            return BoardSlice(id: b.id, items: try await HomeBoardFetcher.fetch(b, limit: limitPerBoard))
          } catch {
            return BoardSlice(id: b.id, items: [])
          }
        }
      }
      var acc: [BoardSlice] = []
      for await p in group { acc.append(p) }
      return acc
    }
    // 只合并本次源的榜，保留其他源已有数据
    for p in parts { homeCharts[p.id] = p.items }
    if parts.allSatisfy({ $0.items.isEmpty }) {
      self.homeChartsError = "榜单加载失败，请检查网络后重试"
    } else {
      // 至少一榜成功才落盘，避免空结果覆盖有效缓存
      self.homeChartsUpdatedAt = Date()
      saveHomeChartsCache()
    }
  }

  /// 全源聚合搜索（并发，单源失败不影响其他源；源来自注册表）
  func searchAll(keyword: String) async {
    await search(keyword: keyword)
  }

  // MARK: 歌单搜索（搜索页"歌单"Tab；对标 any-listen songlistSearch）
  // kw/mg 无公开歌单接口（GD音乐台同源亦无），来源限定 wy/tx/kg。

  enum SearchMode: String, CaseIterable {
    case songs = "单曲"
    case songlists = "歌单"
  }

  var searchMode: SearchMode = .songs
  var slResults: [ALSongListItem] = []
  var slSourceId = SonglistStore.searchableSources.first?.rawValue ?? "wy"
  var slSearching = false
  var slError: String?
  private var slSession = 0

  var slSourceName: String {
    SourceRegistry.capability(id: slSourceId)?.displayName ?? slSourceId
  }

  /// 切换歌单搜索来源（已有关键词时立即重搜）
  func setSonglistSource(_ id: String) async {
    guard id != slSourceId,
          SonglistStore.searchableSources.contains(where: { $0.rawValue == id }) else { return }
    slSourceId = id
    if !keyword.isEmpty {
      await searchSonglists(keyword: keyword)
    }
  }

  func searchSonglists(keyword: String) async {
    let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !kw.isEmpty else { return }
    slSession += 1
    let session = slSession
    slSearching = true
    slError = nil
    defer { slSearching = false }
    do {
      let r = try await AnyListenResource.songlistSearch(
        source: MusicSource(rawValue: slSourceId) ?? .wy, keyword: kw, page: 1, limit: 30)
      guard session == slSession else { return }
      slResults = r.list
    } catch {
      guard session == slSession else { return }
      slResults = []
      slError = error.localizedDescription
    }
  }

  /// 切换搜索模式：进入"歌单"时若有关键词立即拉取
  func setSearchMode(_ mode: SearchMode) async {
    guard mode != searchMode else { return }
    searchMode = mode
    if mode == .songlists, !keyword.isEmpty, slResults.isEmpty {
      await searchSonglists(keyword: keyword)
    }
  }

  private func search(keyword: String) async {
    guard start(keyword: keyword) else { return }
    let kw = self.keyword
    let session = searchSession
    defer { searching = false }
    let order = Dictionary(uniqueKeysWithValues: SourceRegistry.searchable.map { ($0.id, $0.sortOrder) })
    let jobs: [SearchJob] = SourceRegistry.searchable.compactMap { cap in
      guard let ms = MusicSource(rawValue: cap.id),
            enabledSources.contains(ms),
            let fn = cap.search else { return nil }
      return SearchJob(id: cap.id, order: order[cap.id] ?? 99, search: fn)
    }
    let parts = await withTaskGroup(of: SearchSlice.self, returning: [SearchSlice].self) { group in
      for job in jobs {
        group.addTask {
          do {
            let r = try await job.search(kw, 1, 15)
            return SearchSlice(id: job.id, order: job.order, items: r.items)
          } catch { return SearchSlice(id: job.id, order: job.order, items: []) }
        }
      }
      var acc: [SearchSlice] = []
      for await p in group { acc.append(p) }
      return acc
    }
    guard session == searchSession else { return } // 已发起新一轮搜索，丢弃过期结果
    // 注册表顺序稳定排列，扁平化给 results（保留 source 徽标），分组给 multiResults
    let sorted = parts.sorted { $0.order < $1.order }
    multiResults = sorted.compactMap { p in MusicSource(rawValue: p.id).map { ($0, p.items) } }
    results = sorted.flatMap(\.items)
    total = results.count
  }

  /// 换源播放用：在指定源找与目标同名同歌手的第一首（对标 core/music findMusic 单源版）
  func findSimilar(_ song: MusicInfo, in source: MusicSource) async -> MusicInfo? {
    guard let fn = SourceRegistry.capability(id: source.rawValue)?.search else { return nil }
    let items = await Self.searchSimilar(song, search: fn)
    return items.first
  }

  /// 跨源同曲候选（对标 musicSdk.findMusic；换源播放/歌词封面兜底用），排除自身源
  func findSimilarCandidates(_ song: MusicInfo, limitPerSource: Int = 5) async -> [MusicInfo] {
    let jobs: [SearchJob] = SourceRegistry.searchable.compactMap { cap in
      guard cap.id != song.source.rawValue, let fn = cap.search else { return nil }
      return SearchJob(id: cap.id, order: 0, search: fn)
    }
    let parts = await withTaskGroup(of: [MusicInfo].self, returning: [MusicInfo].self) { group in
      for job in jobs {
        group.addTask { await Self.searchSimilar(song, search: job.search, limit: limitPerSource) }
      }
      var acc: [MusicInfo] = []
      for await items in group { acc.append(contentsOf: items) }
      return acc
    }
    return parts
  }

  /// 同曲匹配（对标桌面端 findMusic 的宽松匹配：歌名包含 + 歌手包含）
  /// nonisolated static：不碰 MainActor 状态，可被 TaskGroup 子任务直接调用
  nonisolated private static func searchSimilar(_ song: MusicInfo, search fn: (@Sendable (String, Int, Int) async throws -> (items: [MusicInfo], total: Int))?, limit: Int = 5) async -> [MusicInfo] {
    guard let fn else { return [] }
    let q = "\(song.name) \(song.singer)".trimmingCharacters(in: .whitespaces)
    let items: [MusicInfo]
    do {
      items = try await fn(q, 1, limit).items
    } catch { return [] }
    let norm = { (s: String) in s.lowercased().replacingOccurrences(of: " ", with: "") }
    let ranked = items.sorted {
      scoreSimilar($0, song: song, norm: norm) > scoreSimilar($1, song: song, norm: norm)
    }
    return ranked.filter { scoreSimilar($0, song: song, norm: norm) > 0 }
  }

  nonisolated private static func scoreSimilar(_ item: MusicInfo, song: MusicInfo, norm: (String) -> String) -> Int {
    let nameHit = norm(item.name).contains(norm(song.name)) || norm(song.name).contains(norm(item.name))
    guard nameHit else { return 0 }
    return norm(item.singer).contains(norm(song.singer)) || norm(song.singer).contains(norm(item.singer)) ? 2 : 1
  }
}
