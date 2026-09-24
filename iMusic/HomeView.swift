import SwiftUI

// MARK: - 主页（发现页）
struct HomeView: View {
  @Environment(AppState.self) private var app
  @Environment(SearchService.self) private var search
  @Environment(LibraryStore.self) private var library
  @Binding var sel: SideItem

  @State private var sourceTab: String = {
    let saved = UserDefaults.standard.string(forKey: "home.sourceId") ?? ""
    return HomeBoards.sources.contains(where: { $0.id == saved }) ? saved : HomeBoards.defaultSourceId
  }()
  @State private var boardTab: String = {
    let saved = UserDefaults.standard.string(forKey: "home.boardId") ?? ""
    return HomeBoards.board(id: saved) != nil ? saved : HomeBoards.defaultBoardId
  }()
  @State private var sourceMenuHovered = false
  @State private var randomSource: RandomListenSource = {
    let saved = UserDefaults.standard.string(forKey: "home.randomSource") ?? ""
    return RandomListenSource(rawValue: saved) ?? .all
  }()

  // MARK: - 派生数据

  private var favSongs: [MusicInfo] {
    library.playlists.first(where: { $0.id == "fav" })?.songs ?? []
  }

  private var boards: [HomeBoard] {
    HomeBoards.boards(for: sourceTab)
  }

  private var chartSongs: [MusicInfo] {
    search.homeCharts[boardTab] ?? []
  }

  private func boardCount(_ b: HomeBoard) -> Int {
    search.homeCharts[b.id]?.count ?? 0
  }

  private var heroPick: MusicInfo? {
    chartSongs.first ?? search.hot.first ?? library.history.first ?? favSongs.first
  }

  /// 榜单数据年龄（"刚刚更新 / X分钟前 / X小时前"），缓存场景下告知用户数据新鲜度
  private var chartsAgeText: String? {
    chartAgeText(from: search.homeChartsUpdatedAt)
  }

  private var dateText: String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "M月d日 EEEE"
    return f.string(from: Date())
  }

  // MARK: - 动作

  /// boardTab 归位：保证指向当前源内有数据的榜（优先保持用户选择）
  private func normalizeBoardTab() {
    if board.sourceId != sourceTab || boardCount(board) == 0 {
      if let hasData = boards.first(where: { boardCount($0) > 0 }) {
        boardTab = hasData.id
      } else if board.sourceId != sourceTab, let first = boards.first {
        boardTab = first.id
      }
    }
  }

  private var board: HomeBoard {
    HomeBoards.board(id: boardTab) ?? HomeBoards.board(id: HomeBoards.defaultBoardId)!
  }

  // MARK: - 视图

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        randomListen
        boardCards
      }
      .padding(Theme.spaceLG)
      .spotifyScrollbar()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
    .task {
      if search.hot.isEmpty { await search.loadHot() }
      if !search.hasCharts(for: sourceTab) {
        // 缓存秒开：有效期内展示缓存 + 后台静默刷新；过期/无缓存则前台等待网络
        let fresh = search.restoreHomeChartsCache()
        normalizeBoardTab()
        if fresh {
          Task { await search.loadHomeCharts(for: sourceTab) }
        } else {
          await search.loadHomeCharts(for: sourceTab)
        }
        normalizeBoardTab()
      } else {
        normalizeBoardTab()
      }
    }
    .onChange(of: sourceTab) { _, new in
      UserDefaults.standard.set(new, forKey: "home.sourceId")
      normalizeBoardTab()
      UserDefaults.standard.set(boardTab, forKey: "home.boardId")
      if !search.hasCharts(for: new) {
        Task { await search.loadHomeCharts(for: new) }
      }
    }
    .onChange(of: boardTab) { _, new in
      UserDefaults.standard.set(new, forKey: "home.boardId")
    }
    .onChange(of: randomSource) { _, new in
      UserDefaults.standard.set(new.rawValue, forKey: "home.randomSource")
    }
  }

  // MARK: 来源切换（低感知幽灵文字菜单，收进标题行尾部）
  private var sourceMenu: some View {
    Menu {
      ForEach(HomeBoards.sources, id: \.id) { cap in
        Button {
          sourceTab = cap.id
        } label: {
          HStack(spacing: 6) {
            Text(cap.displayName)
            if sourceTab == cap.id {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 3) {
        Text(HomeBoards.sources.first(where: { $0.id == sourceTab })?.displayName ?? "选择来源")
          .font(Theme.caption())
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .medium))
      }
      .foregroundStyle(sourceMenuHovered ? Theme.text : Theme.text2)
      .contentShape(Rectangle())
      .onHover { sourceMenuHovered = $0 }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("切换榜单来源")
  }

  // MARK: 榜单卡片（对标官方榜卡片：封面 + Top3 预览 + 更新时间，点击进入榜单详情页）

  private var boardCards: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("热门榜单")
          .font(Theme.title())
          .foregroundStyle(Theme.text)
        sourceMenu
          .padding(.top, 4)
        Spacer()
        if let age = chartsAgeText {
          Text(age)
            .font(Theme.caption())
            .foregroundStyle(Theme.text2)
        }
        Button {
          Task { await search.loadHomeCharts(for: sourceTab) }
        } label: {
          Image(systemName: "arrow.clockwise")
            .foregroundStyle(Theme.text2)
        }
        .buttonStyle(.borderless)
        .disabled(search.homeChartsLoading)
        .help("刷新榜单")
      }

      if search.homeChartsLoading && search.loadingSourceId == sourceTab && boards.allSatisfy({ boardCount($0) == 0 }) {
        HStack {
          Spacer()
          ProgressView()
            .padding(.vertical, 28)
          Spacer()
        }
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)],
          spacing: 12
        ) {
          ForEach(boards) { b in
            HomeBoardCard(board: b, songs: search.homeCharts[b.id] ?? [], ageText: chartsAgeText) {
              boardTab = b.id
              sel = .board(b.id)
            }
          }
        }
        .padding(.vertical, 2)
      }

      if let e = search.homeChartsError, boards.allSatisfy({ boardCount($0) == 0 }) {
        Text(e)
          .font(.caption)
          .foregroundStyle(Theme.text2)
      }
    }
  }

  // MARK: 随心听

  private var randomListen: some View {
    RandomListenModule(source: $randomSource) { sel = $0 }
  }
}

// MARK: - 榜单数据年龄（主页卡片与榜单详情共用）

fileprivate func chartAgeText(from t: Date?) -> String? {
  guard let t else { return nil }
  let mins = Int(Date().timeIntervalSince(t) / 60)
  if mins < 1 { return "刚刚更新" }
  if mins < 60 { return "\(mins)分钟前更新" }
  return "\(mins / 60)小时前更新"
}

// MARK: - 榜单详情页（主页榜单卡片点入；对标网易云榜单页：大标题 + 播放全部 + 分列歌曲表）

struct BoardDetailView: View {
  @Environment(SearchService.self) private var search
  @Environment(PlayerStore.self) private var player
  var boardId: String
  @Binding var sel: SideItem

  @State private var songs: [MusicInfo] = []
  @State private var loading = false
  @State private var didLoad = false
  @State private var errorText: String?
  @State private var updatedAt: Date?

  private var board: HomeBoard? { HomeBoards.board(id: boardId) }

  private var sourceName: String {
    guard let b = board else { return "" }
    return HomeBoards.sources.first(where: { $0.id == b.sourceId })?.displayName ?? b.sourceId
  }

  private var ageText: String? {
    chartAgeText(from: updatedAt ?? search.homeChartsUpdatedAt)
  }

  private var subtitleText: String {
    var parts = ["\(sourceName) · 共 \(songs.count) 首"]
    if let age = ageText { parts.append(age) }
    return parts.joined(separator: " · ")
  }

  private var displayTitle: String {
    board?.name ?? "歌单"
  }

  private var displayCategory: String {
    board?.category ?? ""
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        if board != nil {
          detailHeader
          actionBar
          columnHeader
          listBody
        } else {
          EmptyStateView(
            title: "榜单不存在",
            systemImage: "exclamationmark.triangle",
            description: ""
          )
        }
      }
      .padding(24)
      .spotifyScrollbar()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
    .task { await load() }
  }

  // MARK: 大标题

  private var detailHeader: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(displayTitle)
            .font(Theme.display())
            .foregroundStyle(Theme.text)
          if !displayCategory.isEmpty {
            Text(displayCategory)
              .font(Theme.caption(.semibold))
              .foregroundStyle(Theme.accent)
          }
        }
        Text(subtitleText)
          .font(Theme.body())
          .foregroundStyle(Theme.text2)
      }
      Spacer()
    }
  }

  // MARK: 播放全部 / 随机 / 刷新

  private var actionBar: some View {
    HStack(spacing: 10) {
      Button {
        playAll()
      } label: {
        Label("播放全部", systemImage: "play.fill")
          .font(.system(size: 13, weight: .semibold))
          .padding(.horizontal, 6)
      }
      .buttonStyle(.borderedProminent)
      .tint(Theme.accent)
      .foregroundStyle(.black)
      .disabled(songs.isEmpty)

      Button {
        playShuffle()
      } label: {
        Label("随机播放", systemImage: "shuffle")
      }
      .buttonStyle(.bordered)
      .tint(Theme.text2)
      .foregroundStyle(.white)
      .disabled(songs.isEmpty)

      if loading && !songs.isEmpty {
        ProgressView()
          .controlSize(.small)
      }

      Spacer()

      Button {
        Task { await load(force: true) }
      } label: {
        Label(loading ? "刷新中…" : "刷新", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .tint(Theme.text2)
      .foregroundStyle(.white)
      .controlSize(.small)
      .disabled(loading)
    }
  }

  // MARK: 列表头（# / 歌曲 / 专辑 / 喜欢 / 时长）

  private var columnHeader: some View {
    HStack(spacing: 12) {
      Text("#")
        .frame(width: 28, alignment: .leading)
      Color.clear.frame(width: 40, height: 12)
      Text("歌曲")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("专辑")
        .frame(width: 200, alignment: .leading)
      Image(systemName: "heart")
        .frame(width: 24)
      Text("时长")
        .frame(width: 44, alignment: .trailing)
      Color.clear.frame(width: 24, height: 12)
    }
    .font(Theme.caption())
    .foregroundStyle(Theme.text2)
    .padding(.horizontal, 20)
    .padding(.bottom, 6)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Theme.separator)
        .frame(height: 1)
    }
  }

  // MARK: 歌曲表

  @ViewBuilder private var listBody: some View {
    if songs.isEmpty {
      if loading || !didLoad {
        HStack {
          Spacer()
          ProgressView()
            .scaleEffect(1.2)
            .padding(.vertical, 36)
          Spacer()
        }
      } else {
        EmptyStateView(
          title: errorText ?? "该榜单暂无数据",
          systemImage: "chart.bar.xaxis",
          description: "点击刷新重试",
          action: { Task { await load(force: true) } }
        )
      }
    } else {
      LazyVStack(spacing: 0) {
        ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
          BoardChartRow(index: i, song: song, queue: songs)
          if i < songs.count - 1 {
            Divider()
              .padding(.leading, 60)
          }
        }
      }
      .padding(8)
    }
  }

  // MARK: 数据：先展示主页缓存预览（10 首），再拉完整榜单（50 首）

  private func load(force: Bool = false) async {
    guard let b = board else { return }
    if songs.isEmpty { songs = search.homeCharts[b.id] ?? [] }
    guard force || !didLoad else { return }
    loading = true
    defer { loading = false; didLoad = true }
    errorText = nil
    do {
      let full = try await HomeBoardFetcher.fetch(b, limit: 50)
      if full.isEmpty {
        if songs.isEmpty { errorText = "该榜单暂无数据" }
      } else {
        songs = full
        updatedAt = Date()
      }
    } catch {
      if songs.isEmpty { errorText = error.localizedDescription }
    }
  }

  private func playAll() {
    guard let first = songs.first else { return }
    player.play(first, in: songs)
  }

  private func playShuffle() {
    let l = songs.shuffled()
    guard let first = l.first else { return }
    player.play(first, in: l)
  }
}

// MARK: - 榜单详情歌曲行（排名/悬停播放 + 专辑 + 喜欢 + 时长）

private struct BoardChartRow: View {
  @Environment(PlayerStore.self) private var player
  @Environment(LibraryStore.self) private var library
  @Environment(DownloadStore.self) private var downloads
  var index: Int
  var song: MusicInfo
  var queue: [MusicInfo]
  @State private var isHovered = false

  private var isCurrent: Bool { player.current?.id == song.id }

  private var isFav: Bool {
    library.playlists.first(where: { $0.id == "fav" })?.songs.contains(where: { $0.id == song.id }) ?? false
  }

  var body: some View {
    HStack(spacing: 12) {
      ZStack(alignment: .leading) {
          if isHovered {
            Button {
              player.play(song, in: queue)
            } label: {
              Image(systemName: "play.fill")
                .font(.caption.bold())
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
          } else {
          Text(String(format: "%02d", index + 1))
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(index < 3 || isCurrent ? Theme.accent : Theme.text2)
        }
      }
      .frame(width: 28)

      CoverThumb(url: song.picUrl, size: 40, cornerRadius: 8)

      VStack(alignment: .leading, spacing: 2) {
        Text(song.name)
          .font(.callout.weight(.medium))
          .lineLimit(1)
          .foregroundStyle(isCurrent ? Theme.accent : .white)
        Text(song.singer)
          .font(.caption)
          .foregroundStyle(Theme.text2)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(song.albumName)
        .font(.caption)
        .foregroundStyle(Theme.text2)
        .lineLimit(1)
        .frame(width: 200, alignment: .leading)

      Button {
        if isFav { library.remove(song, from: "fav") } else { library.add(song, to: "fav") }
      } label: {
        Image(systemName: isFav ? "heart.fill" : "heart")
          .foregroundStyle(isFav ? Theme.accent : (isHovered ? .white : Theme.text2))
      }
      .buttonStyle(.borderless)
      .frame(width: 24)

      Text(song.interval ?? "")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.text2)
        .frame(width: 44, alignment: .trailing)

      Menu {
        Button("播放") { player.play(song, in: queue) }
        Divider()
        ForEach(library.playlists) { pl in
          Button("加入「\(pl.name)」") { library.add(song, to: pl.id) }
        }
        Divider()
        Button("下载") {
          Task {
            if let url = await player.resolveUrlOnly(song) { downloads.enqueue(song, urlString: url) }
          }
        }
        Button(library.disliked.contains(song.id) ? "取消不喜欢" : "不喜欢") { library.toggleDislike(song) }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isHovered ? Theme.rowHover : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture { player.play(song, in: queue) }
    .onHover { hover in
      isHovered = hover
    }
    .contextMenu {
      Button("播放") { player.play(song, in: queue) }
      Divider()
      ForEach(library.playlists) { pl in
        Button("加入「\(pl.name)」") { library.add(song, to: pl.id) }
      }
      Divider()
      Button("下载") {
        Task {
          if let url = await player.resolveUrlOnly(song) { downloads.enqueue(song, urlString: url) }
        }
      }
      Button(library.disliked.contains(song.id) ? "取消不喜欢" : "不喜欢") { library.toggleDislike(song) }
    }
  }
}

// MARK: - 主页小组件

private enum RandomListenSource: String, CaseIterable, Identifiable {
  case all
  case favorites
  case history

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "全部"
    case .favorites: return "收藏"
    case .history: return "历史"
    }
  }

  var accessibilityTitle: String {
    switch self {
    case .all: return "全部来源"
    case .favorites: return "我的收藏"
    case .history: return "最近播放"
    }
  }

  var contextID: String { "random-listen.\(rawValue)" }
}

private struct RandomListenModule: View {
  @Environment(SearchService.self) private var search
  @Environment(PlayerStore.self) private var player
  @Environment(LibraryStore.self) private var library
  @Binding var source: RandomListenSource
  let navigate: (SideItem) -> Void
  @State private var isPrimaryHovered = false
  @FocusState private var isPrimaryFocused: Bool

  private var rawFavoriteSongs: [MusicInfo] {
    library.playlists.first(where: { $0.id == "fav" })?.songs ?? []
  }

  private var favoriteSongs: [MusicInfo] {
    uniqueSongs(rawFavoriteSongs)
  }

  private var historySongs: [MusicInfo] {
    uniqueSongs(library.history)
  }

  private var pool: [MusicInfo] {
    uniqueSongs(search.hot + library.history + rawFavoriteSongs)
  }

  private var sourceSongs: [MusicInfo] {
    switch source {
    case .all: return pool
    case .favorites: return favoriteSongs
    case .history: return historySongs
    }
  }

  private var hasActiveQueue: Bool {
    player.queueContext == source.contextID && !player.queue.isEmpty
  }
  private var isPrimaryLoading: Bool {
    hasActiveQueue && player.playbackState == .loading
  }
  private var isPrimaryDisabled: Bool {
    (sourceSongs.isEmpty && !hasActiveQueue) || isPrimaryLoading
  }

  private var summaryTitle: String {
    switch source {
    case .all: return "随机播放"
    case .favorites: return "从收藏里随机"
    case .history: return "从最近播放里随机"
    }
  }

  private var summaryDescription: String {
    guard !sourceSongs.isEmpty else {
      switch source {
      case .all: return "正在等待真实歌曲进入候选"
      case .favorites: return "收藏后会从这里随机播放"
      case .history: return "播放过的歌曲会进入候选"
      }
    }
    if sourceSongs.count <= 20 {
      return "将随机排列 \(sourceSongs.count) 首\(source == .all ? "真实歌曲" : "歌曲")"
    }
    return "从 \(sourceSongs.count) 首歌曲中随机挑选 20 首"
  }

  private var excludedCount: Int {
    let songs: [MusicInfo]
    switch source {
    case .all: songs = search.hot + library.history + rawFavoriteSongs
    case .favorites: songs = rawFavoriteSongs
    case .history: songs = library.history
    }
    return Set(songs.filter { library.disliked.contains($0.id) }.map(\.id)).count
  }

  private var primaryTitle: String {
    if hasActiveQueue {
      if isPrimaryLoading { return "正在准备" }
      if player.isPlaying { return "暂停" }
      if player.playbackState == .failed { return "重试播放" }
      return "继续播放"
    }
    switch source {
    case .all: return "开始随机播放"
    case .favorites: return "随机播放收藏"
    case .history: return "随机播放历史"
    }
  }

  private var primarySymbol: String {
    if hasActiveQueue {
      if isPrimaryLoading { return "hourglass" }
      if player.isPlaying { return "pause.fill" }
      if player.playbackState == .failed { return "arrow.clockwise" }
      return "play.fill"
    }
    return "play.fill"
  }

  private var primaryHelp: String {
    if hasActiveQueue {
      if player.isPlaying { return "暂停当前随机队列" }
      if player.playbackState == .failed { return "重试播放当前歌曲" }
      return "继续播放当前随机队列"
    }
    return "随机排列\(source.accessibilityTitle)后开始播放"
  }

  private var readyStatusText: String {
    let count = excludedCount
    return count > 0
      ? "已排除 \(count) 首标记为不喜欢的歌曲"
      : "随机结果只包含当前来源中未标记不喜欢的歌曲"
  }

  private var activeStatusTitle: String {
    guard let name = player.current?.name else { return "随机队列已准备" }
    switch player.playbackState {
    case .idle:
      return "随机队列已准备"
    case .loading:
      return "正在准备「\(name)」"
    case .ready:
      if player.status == "播放结束" { return "随机队列已播放完" }
      return player.isPlaying ? "正在播放「\(name)」" : "已暂停「\(name)」"
    case .failed:
      return "暂时无法播放"
    }
  }

  private var activeStatusDetail: String {
    switch player.playbackState {
    case .idle:
      return "准备完成后会自动开始播放"
    case .loading:
      return "音源解析完成后会自动开始播放"
    case .ready:
      if player.status == "播放结束" { return "继续播放会从最后一首重新开始" }
      if player.isPlaying { return activeQueueDetail }
      return "继续后会从当前歌曲播放"
    case .failed:
      return "\(player.status)。请检查音源设置后重试"
    }
  }

  private var activeQueueDetail: String {
    let position = player.current.flatMap { current in
      player.queue.firstIndex(where: { $0.id == current.id }).map { "\($0 + 1) / \(player.queue.count)" }
    }
    let singer = player.current?.singer.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return [position, singer.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
  }

  private var emptyStatusTitle: String {
    if source == .all, search.hotLoading, pool.isEmpty { return "正在准备热榜" }
    if source == .all, search.error != nil, pool.isEmpty { return "热榜暂时无法加载" }
    switch source {
    case .all: return "还没有可随机歌曲"
    case .favorites: return "收藏里还没有歌曲"
    case .history: return "最近播放还没有歌曲"
    }
  }

  private var emptyStatusDetail: String {
    if source == .all, search.hotLoading, pool.isEmpty {
      return "收藏和最近播放仍会同时加入候选"
    }
    if source == .all, let error = search.error, pool.isEmpty {
      return "\(error)。请重试，或先搜索想听的音乐"
    }
    switch source {
    case .all: return "搜索并收藏歌曲后，即可从这里开始播放"
    case .favorites: return "搜索并收藏歌曲后，就能从这里随机播放"
    case .history: return "播放过的歌曲会出现在这里，也会进入全部随机"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      mainContent
      Divider()
        .overlay(Theme.separator)
      statusView
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
        .fill(Theme.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("随心听")
    .accessibilityValue("\(source.accessibilityTitle)，\(summaryDescription)")
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        titleBlock
        Spacer(minLength: 16)
        sourcePicker
          .frame(width: 260)
      }
      VStack(alignment: .leading, spacing: 12) {
        titleBlock
        sourcePicker
          .frame(maxWidth: 280)
      }
    }
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("随心听")
        .font(Theme.title())
        .foregroundStyle(Theme.text)
      Text("把下一首交给音乐")
        .font(Theme.bodySM())
        .foregroundStyle(Theme.text2)
    }
  }

  private var sourcePicker: some View {
    Picker("随机听来源", selection: $source) {
      ForEach(RandomListenSource.allCases) { item in
        Text(item.title)
          .tag(item)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .tint(Theme.accent)
    .accessibilityLabel("随机听来源")
  }

  private var mainContent: some View {
    HStack(spacing: 14) {
      RoundedRectangle(cornerRadius: Theme.radiusCover, style: .continuous)
        .fill(Theme.field)
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "shuffle")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        Text(summaryTitle)
          .font(Theme.titleLG())
          .foregroundStyle(Theme.text)
          .lineLimit(2)
        Text(summaryDescription)
          .font(Theme.bodySM())
          .foregroundStyle(Theme.text2)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      primaryButton
    }
  }

  private var primaryButton: some View {
    Button(action: performPrimaryAction) {
      HStack(spacing: 8) {
        if isPrimaryLoading {
          ProgressView()
            .controlSize(.small)
            .tint(Theme.sidebar)
        } else {
          Image(systemName: primarySymbol)
            .font(.system(size: 13, weight: .bold))
        }
        Text(primaryTitle)
          .lineLimit(1)
      }
      .font(Theme.body(.semibold))
      .frame(minWidth: 132, minHeight: 40)
    }
    .buttonStyle(RandomListenButtonStyle(hovered: isPrimaryHovered))
    .disabled(isPrimaryDisabled)
    .onHover { isPrimaryHovered = $0 && !isPrimaryDisabled }
    .focused($isPrimaryFocused)
    .focusEffectDisabled()
    .overlay {
      if isPrimaryFocused {
        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
          .stroke(Theme.text, lineWidth: 2)
          .padding(-3)
      }
    }
    .help(primaryHelp)
    .accessibilityHint(primaryHelp)
  }

  @ViewBuilder private var statusView: some View {
    if hasActiveQueue {
      HStack(alignment: .top, spacing: 10) {
        activeStatusIcon
          .frame(width: 20, height: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(activeStatusTitle)
            .font(Theme.body(.semibold))
            .foregroundStyle(player.playbackState == .failed ? Theme.danger : Theme.text)
          Text(activeStatusDetail)
            .font(Theme.bodySM())
            .foregroundStyle(Theme.text2)
            .lineLimit(2)
        }
        Spacer(minLength: 12)
        if player.playbackState == .failed {
          Button("检查音源") { navigate(.source) }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
      }
    } else if sourceSongs.isEmpty {
      HStack(alignment: .top, spacing: 10) {
        emptyStatusIcon
          .frame(width: 20, height: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(emptyStatusTitle)
            .font(Theme.body(.semibold))
            .foregroundStyle(Theme.text)
          Text(emptyStatusDetail)
            .font(Theme.bodySM())
            .foregroundStyle(Theme.text2)
            .lineLimit(2)
        }
        Spacer(minLength: 12)
        emptyAction
      }
    } else {
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Theme.accent)
          .accessibilityHidden(true)
        Text(readyStatusText)
          .font(Theme.bodySM())
          .foregroundStyle(Theme.text2)
        Spacer(minLength: 0)
      }
    }
  }

  @ViewBuilder private var activeStatusIcon: some View {
    if player.playbackState == .loading {
      ProgressView()
        .controlSize(.small)
    } else {
      Image(systemName: player.playbackState == .failed
        ? "exclamationmark.triangle.fill"
        : (player.isPlaying ? "waveform" : "pause.circle"))
        .foregroundStyle(player.playbackState == .failed ? Theme.danger : Theme.accent)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder private var emptyStatusIcon: some View {
    if source == .all, search.hotLoading, pool.isEmpty {
      ProgressView()
        .controlSize(.small)
    } else {
      Image(systemName: "music.note.list")
        .foregroundStyle(Theme.text2)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder private var emptyAction: some View {
    if source != .all, !pool.isEmpty {
      Button("试试全部") { source = .all }
        .buttonStyle(.bordered)
        .controlSize(.small)
    } else if source == .all, search.error != nil, !search.hotLoading, pool.isEmpty {
      Button("重新加载热榜") {
        Task { await search.loadHot() }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    } else if !(source == .all && search.hotLoading && pool.isEmpty) {
      Button("搜索音乐") { navigate(.search) }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
  }

  private func uniqueSongs(_ songs: [MusicInfo]) -> [MusicInfo] {
    var seen = Set<String>()
    return songs.filter {
      !library.disliked.contains($0.id) && seen.insert($0.id).inserted
    }
  }

  private func performPrimaryAction() {
    if hasActiveQueue {
      player.toggle()
      return
    }
    let queue = Array(sourceSongs.shuffled().prefix(20))
    guard let first = queue.first else { return }
    player.mode = .sequence
    player.play(first, in: queue, context: source.contextID)
  }
}

private struct RandomListenButtonStyle: ButtonStyle {
  var hovered: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let fill: Color
    if !isEnabled {
      fill = Theme.cardHover
    } else if configuration.isPressed {
      fill = Theme.accent.opacity(0.82)
    } else {
      fill = hovered ? Theme.accentHover : Theme.accent
    }

    return configuration.label
      .foregroundStyle(isEnabled ? Theme.sidebar : Theme.text2)
      .background(
        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
          .fill(fill)
      )
      .opacity(isEnabled ? 1 : 0.72)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}


private struct HomeBoardCard: View {
  @Environment(PlayerStore.self) private var player
  var board: HomeBoard
  var songs: [MusicInfo]
  var ageText: String?
  var action: () -> Void
  @State private var isHovered = false

  private var tint: Color {
    switch board.category {
    case "推荐": return .red
    case "飙升": return .orange
    case "新歌": return .blue
    case "风格": return .purple
    case "场景": return .teal
            default: return Theme.accent
            }
          }

          private var symbol: String {
    switch board.category {
    case "推荐": return "flame.fill"
    case "飙升": return "chart.line.uptrend.xyaxis"
    case "新歌": return "music.note"
    case "风格": return "guitars"
    case "场景": return "sparkles"
    default: return "music.note.list"
    }
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      // 底层：整卡导航按钮（进详情）
      Button(action: action) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            Text(board.name)
              .font(Theme.body(.semibold))
              .foregroundStyle(Theme.text)
              .lineLimit(1)
            Text(board.category)
              .font(Theme.caption(.semibold))
              .foregroundStyle(Theme.accent)
          }

          HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 5) {
              if songs.isEmpty {
                Text("点击进入重试")
                  .font(Theme.caption())
                  .foregroundStyle(Theme.text2)
              } else {
                ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { i, s in
                  HStack(spacing: 6) {
                    Text("\(i + 1)")
                      .font(Theme.caption(.bold))
                      .foregroundStyle(Theme.accent)
                    Text("\(s.name) - \(s.singer)")
                      .font(Theme.caption())
                      .foregroundStyle(Theme.text2)
                      .lineLimit(1)
                  }
                }
              }
            }
            .frame(height: 56, alignment: .top)
            Spacer(minLength: 0)
            // 占位，避免文案被悬浮键遮挡
            Color.clear.frame(width: 40, height: 40)
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
      }
      .buttonStyle(.plain)

      // 顶层：悬浮绿播放键（同级 Button，命中互斥，只播放不导航）
      if isHovered && !songs.isEmpty {
        Button {
          guard let first = songs.first else { return }
          player.play(first, in: songs)
        } label: {
          Image(systemName: "play.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Theme.accentHover))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .help("播放「\(board.name)」")
        .padding(.trailing, 14)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
        .fill(isHovered ? Theme.cardHover : Theme.card)
    )
    .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    .onHover { isHovered = $0 }
  }

  @ViewBuilder private var cover: some View {
    if let url = songs.first?.picUrl {
      CoverThumb(url: url, size: 76, cornerRadius: Theme.radiusCard)
    } else {
      RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
        .fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(width: 76, height: 76)
        .overlay {
          Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(.white.opacity(0.92))
        }
    }
  }
}

private struct HomeSectionHeader: View {
  var title: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    HStack {
      Text(title)
        .font(Theme.title())
        .foregroundStyle(Theme.text)
      Spacer()
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.link)
          .tint(Theme.accent)
          .controlSize(.small)
      }
    }
  }
}
