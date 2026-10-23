import Foundation
import Observation

// MARK: - 在线歌单浏览（对标 any-listen 歌单页：源/排序/标签 → 歌单卡片 → 详情）
// 数据全部经 any-listen 解析层（AnyListenResource.songlist*）；
// kw/mg 无公开歌单接口（GD音乐台同源亦无），不列入浏览源；kg 仅支持搜索+详情（走搜索页）。

@Observable @MainActor
final class SonglistStore {
  // MARK: 浏览态
  var sourceId = SonglistStore.browsableSources.first?.rawValue ?? "wy"
  var sorts: [ALTagItem] = []
  var selectedSortId = ""
  /// 热门标签（优先展示）；完整分组见 tagGroups
  var tags: [ALTagItem] = []
  var tagGroups: [ALTagGroupItem] = []
  var selectedTagId = "" // "" = 全部
  var lists: [ALSongListItem] = []
  var page = 1
  var total = 0
  var loading = false
  var loadingMore = false
  var error: String?
  /// 会话号：换源/换标签/换排序 +1，丢弃过期响应
  var browseSession = 0

  // MARK: 详情态（页内就地切换）
  var openedList: ALSongListItem?
  var openedSourceId = ""
  var detailSongs: [MusicInfo] = []
  var detailInfo: ALSongListDetailInfo?
  var detailTotal = 0
  var detailLoading = false
  var detailError: String?

  /// 支持标签浏览的源（kw/mg 无公开歌单接口）
  static let browsableSources: [MusicSource] = [.wy, .tx]
  /// 支持歌单搜索的源
  static let searchableSources: [MusicSource] = [.wy, .tx, .kg]

  private var tagsLoadedSource = ""
  private var browseLoadedKey = ""

  var sourceName: String {
    SourceRegistry.capability(id: sourceId)?.displayName ?? sourceId
  }

  var openedSourceName: String {
    SourceRegistry.capability(id: openedSourceId)?.displayName ?? openedSourceId
  }

  private var browseKey: String { "\(sourceId)|\(selectedSortId)|\(selectedTagId)" }

  // MARK: 动作

  func switchSource(_ id: String) async {
    guard id != sourceId, Self.browsableSources.contains(where: { $0.rawValue == id }) else { return }
    sourceId = id
    selectedSortId = ""
    selectedTagId = ""
    await reload()
  }

  func selectSort(_ id: String) async {
    guard id != selectedSortId else { return }
    selectedSortId = id
    await reload()
  }

  func selectTag(_ id: String) async {
    guard id != selectedTagId else { return }
    selectedTagId = id
    await reload()
  }

  /// 首次进入页面：按当前 key 拉取
  func loadIfNeeded() async {
    guard browseLoadedKey != browseKey else { return }
    await reload()
  }

  /// 重新拉取当前标签/排序的歌单列表（换源时顺带刷新标签与排序）
  func reload() async {
    browseSession += 1
    let session = browseSession
    browseLoadedKey = browseKey
    loading = true
    error = nil
    page = 1
    defer { loading = false }
    guard let source = MusicSource(rawValue: sourceId) else { return }
    if tagsLoadedSource != sourceId {
      let tg = await AnyListenResource.songlistTags(source: source)
      let st = await AnyListenResource.songlistSorts(source: source)
      guard session == browseSession else { return }
      tagGroups = tg.tags
      tags = tg.hotTags.isEmpty ? tg.tags.flatMap(\.list) : tg.hotTags
      sorts = st
      if !sorts.contains(where: { $0.id == selectedSortId }) {
        selectedSortId = sorts.first?.id ?? ""
      }
      tagsLoadedSource = sourceId
    }
    do {
      let r = try await AnyListenResource.songlist(source: source, sort: selectedSortId, tag: selectedTagId, page: 1, limit: 30)
      guard session == browseSession else { return }
      lists = r.list
      total = r.total
    } catch {
      guard session == browseSession else { return }
      lists = []
      total = 0
      self.error = error.localizedDescription
    }
  }

  /// 翻页（按 id 去重；返回空则视为到底）
  func loadMore() async {
    guard !loading, !loadingMore, !lists.isEmpty else { return }
    if total > 0, lists.count >= total { return }
    loadingMore = true
    defer { loadingMore = false }
    let session = browseSession
    let nextPage = page + 1
    do {
      let r = try await AnyListenResource.songlist(
        source: MusicSource(rawValue: sourceId) ?? .wy,
        sort: selectedSortId, tag: selectedTagId, page: nextPage, limit: 30)
      guard session == browseSession, !r.list.isEmpty else { return }
      page = nextPage
      let known = Set(lists.map(\.id))
      lists.append(contentsOf: r.list.filter { !known.contains($0.id) })
      total = max(r.total, lists.count)
    } catch {
      if session == browseSession { self.error = error.localizedDescription }
    }
  }

  /// 打开歌单详情（搜索页可跨源打开：fromSource 指定来源）
  func open(_ item: ALSongListItem, fromSource sid: String? = nil) async {
    let srcRaw = sid ?? sourceId
    guard let source = MusicSource(rawValue: srcRaw), source != .local else { return }
    openedList = item
    openedSourceId = srcRaw
    detailSongs = []
    detailInfo = nil
    detailTotal = 0
    detailError = nil
    detailLoading = true
    defer { detailLoading = false }
    do {
      let r = try await AnyListenResource.songlistDetail(source: source, id: item.id, page: 1, limit: 100)
      detailSongs = r.list
      detailInfo = r.info
      detailTotal = r.total
    } catch {
      detailError = error.localizedDescription
    }
  }

  func closeDetail() {
    openedList = nil
    openedSourceId = ""
    detailSongs = []
    detailInfo = nil
    detailTotal = 0
    detailError = nil
  }
}
