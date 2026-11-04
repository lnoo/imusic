import SwiftUI
import Observation

// MARK: - Spotify 深色 UI：纯黑侧栏 / #121212 内容区 / 全宽底部播放条

// MARK: - 源脚本更新横幅（engine 收到 lx.send('updateAlert') 时显示，如版本过低提醒）
struct SourceUpdateBanner: Identifiable, Equatable {
  let id = UUID()
  let message: String
  let updateUrl: String?
}

// MARK: - 源脚本更新横幅视图
struct SourceUpdateBannerView: View {
  let banner: SourceUpdateBanner
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "arrow.down.circle.fill")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(Theme.accent)

      Text(banner.message)
        .font(Theme.caption())
        .foregroundStyle(Theme.text)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let urlStr = banner.updateUrl, let url = URL(string: urlStr) {
        Button("立即更新") {
          NSWorkspace.shared.open(url)
          onDismiss()
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .controlSize(.small)
      }

      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.text2)
      }
      .buttonStyle(.plain)
      .help("关闭")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
        .fill(Theme.accent.opacity(0.12))
        .overlay(
          RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
            .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
        )
    )
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}

struct EmptyStateView: View {
  let title: String
  let systemImage: String
  let description: String
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(Theme.text2)
        .frame(width: 72, height: 72)
        .background(Circle().fill(Theme.cardHover))
      Text(title)
        .font(Theme.title())
        .foregroundStyle(Theme.text)
      if !description.isEmpty {
        Text(description)
          .font(.subheadline)
          .foregroundStyle(Theme.text2)
          .multilineTextAlignment(.center)
      }
      if let action {
        Button("重试", action: action)
          .buttonStyle(.borderedProminent)
          .tint(Theme.accent)
          .padding(.top, 6)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}

// MARK: - 通用 Tab 栏（扁平深色 + 播放绿选中态，贴左对齐，全宽底边线）
// 任何"单曲/歌单"式页内切换都可复用：传 (id, label) 列表 + 选中绑定 + 切换回调。
struct TabPillBar<ID: Hashable>: View {
  struct Item: Hashable {
    let id: ID
    let label: String
  }
  let items: [Item]
  @Binding var selection: ID
  var onSelect: (ID) -> Void = { _ in }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ForEach(items, id: \.id) { item in
          TabButton(
            label: item.label,
            selected: item.id == selection
          ) {
            selection = item.id
            onSelect(item.id)
          }
          .padding(.trailing, 20)
        }
      }
      .padding(.top, 8)
      .padding(.bottom, 10)

      Rectangle()
        .fill(Theme.separator)
        .frame(height: 1)
    }
    .accessibilityElement(children: .contain)
  }

  private struct TabButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
      Button(action: action) {
        Text(label)
          .font(Theme.body(selected ? .bold : .semibold))
          .foregroundStyle(selected ? Theme.text : Theme.text2)
          .overlay(alignment: .bottom) {
            if selected {
              Capsule()
                .fill(Theme.accent)
                .frame(height: 2.5)
                .offset(y: 7.5)
            }
          }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("切换到\(label)")
      .accessibilityLabel(label)
      .accessibilityAddTraits(selected ? .isSelected : [])
    }
  }
}

enum SideItem: Hashable {
  case home, search, songlists, nowPlaying, history, downloads, source
  case playlist(String)
  case board(String)
  case songlistDetail(ALSongListItem, source: String)
}

// MARK: - 主框架 (ContentView)：侧栏 + 内容 + 全宽播放条
struct ContentView: View {
  @Environment(AppState.self) private var state
  @Environment(LibraryStore.self) private var library
  @Environment(SearchService.self) private var search
  @State private var sel: SideItem = .home
  @State private var backStack: [SideItem] = []
  @State private var forwardStack: [SideItem] = []
  @State private var historyNavTarget: SideItem?
  @State private var scriptErrorBanner: SourceUpdateBanner?

  private func goBack() {
    guard !backStack.isEmpty else { return }
    let prev = backStack.removeLast()
    forwardStack.append(sel)
    historyNavTarget = prev
    sel = prev
  }

  private func goForward() {
    guard !forwardStack.isEmpty else { return }
    let next = forwardStack.removeLast()
    backStack.append(sel)
    historyNavTarget = next
    sel = next
  }

  var body: some View {
    @Bindable var search = search
    VStack(spacing: 0) {
      // 脚本错误/更新横幅
      if let banner = scriptErrorBanner {
        SourceUpdateBannerView(banner: banner) {
          scriptErrorBanner = nil
        }
      }
      
      HStack(spacing: 0) {
        SidebarView(sel: $sel)
          .frame(width: 232)

        Rectangle()
          .fill(Theme.separator)
          .frame(width: 1)

        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Theme.bg)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      PlayerBar(sel: $sel)
        .zIndex(1)
    }
    .background(Theme.sidebar)
    .preferredColorScheme(.dark)
    // 源脚本更新提示统一走顶部横幅（SourceUpdateBannerView）：
    // onChange 兜运行中收到的 alert，onAppear 兜视图安装前已存在的 alert
    .onChange(of: state.api.updateAlert) { _, newAlert in
      if let alert = newAlert {
        scriptErrorBanner = SourceUpdateBanner(message: alert.log, updateUrl: alert.updateUrl)
      }
    }
    .onAppear {
      if let alert = state.api.updateAlert {
        scriptErrorBanner = SourceUpdateBanner(message: alert.log, updateUrl: alert.updateUrl)
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        HStack(spacing: 6) {
          Button(action: goBack) {
            Image(systemName: "chevron.left")
          }
          .disabled(backStack.isEmpty)
          .help("后退")

          Button(action: goForward) {
            Image(systemName: "chevron.right")
          }
          .disabled(forwardStack.isEmpty)
          .help("前进")
        }
      }

      ToolbarItem(placement: .primaryAction) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 13))
            .foregroundStyle(Theme.text2)
          TextField("搜索歌曲、歌手、专辑", text: $search.keyword)
            .frame(width: 220)
            .onSubmit {
              search.clearSuggestions()
              let kw = search.keyword
              sel = .search
              Task {
                if search.searchMode == .songlists {
                  await search.searchSonglists(keyword: kw)
                } else {
                  await search.searchAll(keyword: kw)
                }
              }
            }
          // 输入触发 mg 搜索提示（250ms 防抖）
          .onChange(of: search.keyword) { _, kw in
            if kw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              search.clearSuggestions()
            } else {
              search.suggest(kw)
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .fill(Theme.field)
        )
        // 搜索建议下拉（mg tipSearch）
        .overlay(alignment: .topLeading) {
          if search.showSuggestions, !search.suggestions.isEmpty {
            SuggestionsDropdown(items: search.suggestions) { word in
              search.clearSuggestions()
              search.keyword = word
              sel = .search
              Task { await search.searchAll(keyword: word) }
            }
            .offset(y: 36)
            .frame(width: 240, alignment: .leading)
            .zIndex(10)
          }
        }
      }
    }
    .task { await state.reloadSource() }
    .onChange(of: state.api.activeSourceId) { _, _ in
      Task { await state.reloadSource() }
    }
    .onChange(of: sel) { old, new in
      if historyNavTarget == new {
        historyNavTarget = nil
      } else {
        backStack.append(old)
        forwardStack.removeAll()
      }
    }
  }

  @ViewBuilder private var detail: some View {
    switch sel {
    case .home: HomeView(sel: $sel)
    case .search: SearchView(sel: $sel)
    case .songlists: SonglistBrowseView(sel: $sel)
    case .songlistDetail(let item, let source): SonglistDetailView(item: item, source: source)
    case .nowPlaying: NowPlayingView(sel: $sel)
    case .history: HistoryView()
    case .downloads: DownloadsView()
    case .source: SourceSettingsView()
    case .playlist(let id): PlaylistView(playlistId: id)
    case .board(let id): BoardDetailView(boardId: id, sel: $sel)
    }
  }
}

// MARK: - 侧栏（纯黑 + Spotify 导航行）
struct SidebarView: View {
  @Environment(LibraryStore.self) private var library
  @Binding var sel: SideItem

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        navLabel("发现")
        navRow(.home, title: "主页", icon: "house.fill")
        navRow(.search, title: "搜索", icon: "magnifyingglass")
        navRow(.songlists, title: "歌单", icon: "square.grid.2x2")
        navRow(.nowPlaying, title: "正在播放", icon: "play.circle.fill")
        navRow(.source, title: "音源设置", icon: "dot.radiowaves.left.and.right")

        navLabel("我的音乐")
        ForEach(library.playlists) { pl in
          navRow(.playlist(pl.id), title: pl.name, icon: pl.id == "fav" ? "heart.fill" : "music.note.list")
        }
        navRow(.history, title: "最近播放", icon: "clock")
        navRow(.downloads, title: "下载", icon: "arrow.down.circle")

        Spacer(minLength: 24)
      }
      .padding(.bottom, 12)
    }
    .background(Theme.sidebar)
  }

  private func navLabel(_ title: String) -> some View {
    Text(title)
      .font(Theme.caption(.bold))
      .foregroundStyle(Theme.text2)
      .tracking(0.4)
      .padding(.horizontal, Theme.spaceMD)
      .padding(.top, 14)
      .padding(.bottom, 4)
  }

  private func navRow(_ item: SideItem, title: String, icon: String) -> some View {
    let active = sel == item
    return Button {
      sel = item
    } label: {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .font(Theme.body())
          .frame(width: 18)
        Text(title)
          .font(Theme.body(active ? .semibold : .medium))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .foregroundStyle(active ? Theme.text : Theme.text2)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .contentShape(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
      .background(
        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
          .fill(active ? Theme.navHover : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .padding(.vertical, 2)
  }
}

// MARK: - 全宽底部播放条
struct PlayerBar: View {
  @Environment(PlayerStore.self) private var player
  @Environment(LibraryStore.self) private var library
  @Environment(DownloadStore.self) private var downloads
  @Binding var sel: SideItem
  @State private var isDraggingSlider = false
  @State private var dragProgress: Double = 0
  @State private var pendingSeekTask: Task<Void, Never>?
  @State private var showVolume = false
  @State private var isHoveringVolume = false
  @State private var dismissVolumeTask: Task<Void, Never>?
  @State private var isHoverCover = false
  @State private var isHoverPlay = false

  private var currentSong: MusicInfo? { player.current }

  /// 次级行内容：加载/失败态展示 status（解析进展、失败原因），稳态显示歌手。
  /// status 的稳态文案（"正在播放 X"/"已暂停"）与播控按钮状态冗余，不展示。
  private var secondaryLine: (text: String, color: Color, help: String) {
    switch player.playbackState {
    case .failed:
      return (player.status, Theme.warning, player.status)
    case .loading:
      return (player.status, Theme.text2, player.status)
    case .idle, .ready:
      let singer = player.current?.singer ?? ""
      return (singer, Theme.text2, singer)
    }
  }

  private var displayedCurrentTime: Double {
    guard player.duration.isFinite, player.duration > 0 else { return 0 }
    return isDraggingSlider ? player.duration * dragProgress : player.currentTime
  }
  private var isLiked: Bool {
    guard let song = currentSong else { return false }
    return library.playlists.first(where: { $0.id == "fav" })?.songs.contains(where: { $0.id == song.id }) ?? false
  }

  private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let totalSeconds = Int(seconds)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let remainingSeconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%02d:%02d", minutes, remainingSeconds)
  }

  private func scheduleSeek(_ value: Double) {
    pendingSeekTask?.cancel()
    pendingSeekTask = Task {
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else { return }
      player.seek(value)
      isDraggingSlider = false
    }
  }

  private func commitSeek(_ value: Double) {
    pendingSeekTask?.cancel()
    player.seek(value)
    isDraggingSlider = false
  }

  private func resetSlider() {
    pendingSeekTask?.cancel()
    isDraggingSlider = false
    dragProgress = player.progress
  }

  private func toggleLike() {
    guard let song = currentSong else { return }
    if isLiked {
      library.remove(song, from: "fav")
    } else {
      library.add(song, to: "fav")
    }
  }

  private func download() {
    guard let song = currentSong else { return }
    Task {
      if let url = await player.resolveUrlOnly(song) {
        downloads.enqueue(song, urlString: url)
      }
    }
  }

  var body: some View {
    HStack(spacing: 16) {
      // 左：曲目信息
      HStack(spacing: 12) {
        Button {
          sel = .nowPlaying
        } label: {
          CoverThumb(url: player.current?.picUrl, size: 48, cornerRadius: Theme.radiusCover)
            .overlay(
              RoundedRectangle(cornerRadius: Theme.radiusCover, style: .continuous)
                .stroke(Color.white.opacity(isHoverCover ? 0.2 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("打开正在播放")
        .onHover { isHoverCover = $0 }

        VStack(alignment: .leading, spacing: 3) {
          Text(player.current?.name ?? "未在播放")
            .font(Theme.body(.semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)

          // 次级行：加载/失败态展示 status 实时进展（解析中/换源中/失败原因），稳态显示歌手
          Text(secondaryLine.text)
            .font(Theme.caption())
            .foregroundStyle(secondaryLine.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(secondaryLine.help)
            .accessibilityLabel(secondaryLine.help)
        }
      }
      .frame(width: 240, alignment: .leading)

      Spacer(minLength: 8)

      // 中：播控 + 进度
      VStack(spacing: 6) {
        HStack(spacing: 18) {
          Button {
            player.cycleMode()
          } label: {
            Image(systemName: player.modeIcon)
              .font(.system(size: 13))
              .frame(width: 20, alignment: .center)
              .foregroundStyle(player.modeIcon == "repeat.1" ? Theme.accent : Theme.text2)
          }
          .buttonStyle(.plain)
          .help("播放模式：\(player.mode.rawValue)")

          Button {
            player.prev()
          } label: {
            Image(systemName: "backward.fill")
              .font(.system(size: 14))
              .foregroundStyle(Theme.text2)
          }
          .buttonStyle(.plain)
          .disabled(!player.canGoPrevious)
          .opacity(player.canGoPrevious ? 1 : 0.35)
          .help("上一首")
          .accessibilityLabel("上一首")

          Button {
            player.toggle()
          } label: {
            Image(systemName: {
              if case .failed = player.playbackState { return "arrow.clockwise" }
              return player.isPlaying ? "pause.fill" : "play.fill"
            }())
              .font(.system(size: 14, weight: .bold))
              .foregroundStyle(.black)
              .frame(width: 32, height: 32)
              .background(Circle().fill(currentSong == nil ? Theme.cardHover : .white))
              .scaleEffect(isHoverPlay ? 1.06 : 1.0)
              .animation(.easeOut(duration: 0.12), value: isHoverPlay)
          }
          .buttonStyle(.plain)
          .disabled(!player.canTogglePlayback)
          .opacity(player.canTogglePlayback ? 1 : 0.5)
          .onHover { isHoverPlay = $0 }
          .help({
            if case .failed = player.playbackState { return "重试播放" }
            return player.isPlaying ? "暂停" : "播放"
          }())
          .accessibilityLabel({
            if case .failed = player.playbackState { return "重试播放" }
            return player.isPlaying ? "暂停" : "播放"
          }())

          Button {
            player.next()
          } label: {
            Image(systemName: "forward.fill")
              .font(.system(size: 14))
              .foregroundStyle(Theme.text2)
          }
          .buttonStyle(.plain)
          .disabled(!player.canGoNext)
          .opacity(player.canGoNext ? 1 : 0.35)
          .help("下一首")
          .accessibilityLabel("下一首")
        }

        HStack(spacing: 8) {
          Text(formatTime(displayedCurrentTime))
            .font(Theme.monoCaption())
            .foregroundStyle(Theme.text2)
            .frame(width: 36, alignment: .trailing)
            .accessibilityHidden(true)

          Slider(
            value: Binding(
              get: { isDraggingSlider ? dragProgress : player.progress },
              set: { value in
                dragProgress = value
                isDraggingSlider = true
                scheduleSeek(value)
              }
            ),
            in: 0...1,
            onEditingChanged: { isEditing in
              if isEditing {
                isDraggingSlider = true
              } else {
                commitSeek(dragProgress)
              }
            }
          )
            .controlSize(.mini)
            .tint(Theme.accent)
            .disabled(!player.canSeek)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(formatTime(displayedCurrentTime))，总时长 \(formatTime(player.duration))")

          Text(formatTime(player.duration))
            .font(Theme.monoCaption())
            .foregroundStyle(Theme.text2)
            .frame(width: 36, alignment: .leading)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: 480)
      }
      .frame(maxWidth: 560)

      Spacer(minLength: 8)

      // 右：喜欢 / 下载 / 音量（滑条浮动，不占文档流）
      HStack(spacing: 12) {
        Button(action: toggleLike) {
          Image(systemName: isLiked ? "heart.fill" : "heart")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isLiked ? Theme.accent : Theme.text2)
            .symbolEffect(.bounce, value: isLiked)
        }
        .buttonStyle(.plain)
        .help(isLiked ? "从我喜欢中移除" : "加入我喜欢")
        .disabled(currentSong == nil)
        .opacity(currentSong == nil ? 0.35 : 1)

        Button(action: download) {
          Image(systemName: "arrow.down.circle")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text2)
        }
        .buttonStyle(.plain)
        .help("下载")
        .disabled(currentSong == nil)
        .opacity(currentSong == nil ? 0.35 : 1)

        Button {
          withAnimation(.easeInOut(duration: 0.15)) { showVolume.toggle() }
        } label: {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : player.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
              .font(.system(size: 13))
              .frame(width: 20, alignment: .center)
              .foregroundStyle(showVolume ? .white : Theme.text2)
        }
        .buttonStyle(.plain)
        .help("音量")
        .onHover { hovering in
          if hovering {
            dismissVolumeTask?.cancel()
            isHoveringVolume = true
          } else {
            isHoveringVolume = false
            scheduleVolumeDismiss()
          }
        }
        .overlay(alignment: .trailing) {
          if showVolume {
            Slider(
              value: Binding(
                get: { player.volume },
                set: { player.setVolume($0) }
              ),
              in: 0...1
            )
            .controlSize(.mini)
            .tint(.white)
            .frame(width: 90)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              Capsule()
                .fill(Theme.cardHover)
                .overlay(
                  Capsule()
                    .stroke(Theme.separator, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            )
            .fixedSize()
            .offset(x: -30, y: 0)
            .onHover { hovering in
              if hovering {
                dismissVolumeTask?.cancel()
                isHoveringVolume = true
              } else {
                isHoveringVolume = false
                scheduleVolumeDismiss()
              }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
          }
        }
        .zIndex(2)
      }
      .frame(alignment: .trailing)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .frame(height: 84)
    .frame(maxWidth: .infinity)
    .background(
      Rectangle()
        .fill(Theme.card)
        .overlay(alignment: .top) {
          Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
        }
    )
    .zIndex(1)
    .onChange(of: player.current?.id) { _, _ in
      resetSlider()
    }
    .onDisappear {
      pendingSeekTask?.cancel()
      isDraggingSlider = false
    }
  }

  private func scheduleVolumeDismiss() {
    dismissVolumeTask?.cancel()
    dismissVolumeTask = Task {
      try? await Task.sleep(nanoseconds: 180_000_000)
      guard !Task.isCancelled, !isHoveringVolume else { return }
      withAnimation(.easeInOut(duration: 0.12)) {
        showVolume = false
      }
    }
  }
}

// MARK: - 歌曲行（表格式 + 悬浮）
struct SongRow: View {
  @Environment(PlayerStore.self) private var player
  @Environment(LibraryStore.self) private var library
  @Environment(DownloadStore.self) private var downloads
  var song: MusicInfo
  var queue: [MusicInfo]
  var playlistId: String? = nil
  var showIndex: Int? = nil
  @State private var isHovered = false

  private var isCurrentPlaying: Bool {
    player.current?.id == song.id && player.isPlaying
  }
  private var isCurrent: Bool { player.current?.id == song.id }
  private var isInFavPlaylist: Bool {
    playlistId == "fav" && library.playlists.first(where: { $0.id == "fav" })?.songs.contains(where: { $0.id == song.id }) ?? false
  }

  var body: some View {
    HStack(spacing: 12) {
      if let idx = showIndex {
        ZStack {
          if isHovered || isCurrentPlaying {
            Button {
              player.play(song, in: queue)
            } label: {
              Image(systemName: isCurrentPlaying ? "speaker.wave.2.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
          } else {
            Text(String(format: "%02d", idx))
              .font(.system(size: 12, weight: .medium, design: .monospaced))
              .foregroundStyle(isCurrent ? Theme.accent : Theme.text2)
          }
        }
        .frame(width: 24)
      } else {
        ZStack {
          if isCurrentPlaying {
            Image(systemName: "speaker.wave.2.fill")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(Theme.accent)
          } else {
            CoverThumb(url: song.picUrl, size: 40, cornerRadius: Theme.radiusCover)
          }
        }
        .frame(width: 40, height: 40)
      }

      if showIndex != nil {
        CoverThumb(url: song.picUrl, size: 40, cornerRadius: Theme.radiusCover)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(song.name)
          .font(Theme.body())
          .lineLimit(1)
          .foregroundStyle(isCurrent ? Theme.accent : Theme.text)

        Text("\(song.singer) · \(song.albumName)")
          .font(Theme.bodySM())
          .foregroundStyle(Theme.text2)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      if !song.albumName.isEmpty && showIndex != nil {
        Text(song.albumName)
          .font(.system(size: 12))
          .foregroundStyle(Theme.text2)
          .lineLimit(1)
          .frame(maxWidth: 180, alignment: .leading)
          .opacity(isHovered ? 1 : 0.85)
      }

      if let interval = song.interval, !interval.isEmpty {
        Text(interval)
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(Theme.text2)
          .frame(width: 40, alignment: .trailing)
      }

      Button {
        if isLiked {
          library.remove(song, from: "fav")
        } else {
          library.add(song, to: "fav")
        }
      } label: {
        Image(systemName: isLiked ? "heart.fill" : "heart")
          .font(.system(size: 13))
          .foregroundStyle(isLiked ? Theme.accent : (isHovered ? .white : Theme.text2))
      }
      .buttonStyle(.plain)
      .opacity(isHovered || isLiked ? 1 : 0)
      .frame(width: 24)

      Button {
        player.play(song, in: queue)
      } label: {
        Image(systemName: isCurrentPlaying ? "pause.circle.fill" : "play.circle.fill")
          .font(.system(size: 22))
          .foregroundStyle(isCurrentPlaying ? Theme.accent : (isHovered ? .white : Theme.text2))
      }
      .buttonStyle(.plain)

      Menu {
        ForEach(library.playlists) { pl in
          if pl.id == "fav" && isInFavPlaylist {
            Button("移除", role: .destructive) { library.remove(song, from: "fav") }
          } else if pl.id != "fav" || !isInFavPlaylist {
            Button("加入「\(pl.name)」") { library.add(song, to: pl.id) }
          }
        }
        Divider()
        Button("下载") {
          Task {
            if let url = await player.resolveUrlOnly(song) { downloads.enqueue(song, urlString: url) }
          }
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
          .foregroundStyle(isHovered ? .white : Theme.text2)
      }
      .buttonStyle(.borderless)
      .opacity(isHovered ? 1 : 0.45)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .background(
      RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
        .fill(isHovered ? Theme.rowHover : Color.clear)
    )
    .onTapGesture(count: 2) {
      player.play(song, in: queue)
    }
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("播放") { player.play(song, in: queue) }
      Divider()
      Button(isLiked ? "移除喜欢" : "加入我喜欢") {
        if isLiked { library.remove(song, from: "fav") } else { library.add(song, to: "fav") }
      }
      ForEach(library.playlists.filter { $0.id != "fav" }) { pl in
        Button("加入「\(pl.name)」") { library.add(song, to: pl.id) }
      }
      Divider()
      Button("下载") {
        Task {
          if let url = await player.resolveUrlOnly(song) { downloads.enqueue(song, urlString: url) }
        }
      }
    }
  }

  private var isLiked: Bool {
    library.playlists.first(where: { $0.id == "fav" })?.songs.contains(where: { $0.id == song.id }) ?? false
  }
}

// MARK: - 播放全部按钮（歌单 / 最近播放共用）
struct PlayAllButton: View {
  var count: Int
  var action: () -> Void
  @State private var isHovered = false

  private var isEnabled: Bool { count > 0 }
  private var helpText: String {
    isEnabled ? "按列表顺序播放这 \(count) 首歌曲" : "列表为空"
  }

  var body: some View {
    Button(action: action) {
      Label("播放全部", systemImage: "play.fill")
        .font(Theme.body(.semibold))
        .frame(minWidth: 92, minHeight: 40)
    }
    .buttonStyle(PlayAllButtonStyle(hovered: isHovered))
    .disabled(!isEnabled)
    .onHover { isHovered = $0 && isEnabled }
    .help(helpText)
    .accessibilityLabel("播放全部")
    .accessibilityHint(helpText)
  }
}

private struct PlayAllButtonStyle: ButtonStyle {
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

// MARK: - 歌曲表列头
struct SongTableHeader: View {
  var showIndex: Bool = false
  var showAlbum: Bool = false

  var body: some View {
    HStack(spacing: 12) {
      if showIndex {
        Text("#")
          .frame(width: 24, alignment: .center)
      } else {
        Color.clear.frame(width: 40, height: 12)
      }
      if showIndex {
        Color.clear.frame(width: 40, height: 12)
      }
      Text("标题")
        .frame(maxWidth: .infinity, alignment: .leading)
      if showAlbum {
        Text("专辑")
          .frame(maxWidth: 180, alignment: .leading)
      }
      Text("时长")
        .frame(width: 40, alignment: .trailing)
      Color.clear.frame(width: 24, height: 12)
      Color.clear.frame(width: 24, height: 12)
      Color.clear.frame(width: 24, height: 12)
    }
    .font(Theme.caption())
    .foregroundStyle(Theme.text2)
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Theme.separator)
        .frame(height: 1)
    }
  }
}

struct CoverThumb: View {
  var url: String?
  var size: CGFloat = 40
  var cornerRadius: CGFloat = 6

  var body: some View {
    Group {
      if let u = url, let link = URL(string: u) {
        AsyncImage(url: link) { phase in
          switch phase {
          case .success(let img):
            img.resizable().aspectRatio(contentMode: .fill)
          case .failure:
            fallback
          case .empty:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
              .fill(Theme.cardHover)
          @unknown default:
            fallback
          }
        }
      } else {
        fallback
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }

  private var fallback: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(Theme.cardHover)
      .overlay(Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(Theme.text2))
  }
}

// MARK: - 搜索建议下拉（mg tipSearch 结果；点击直接搜）
struct SuggestionsDropdown: View {
  var items: [String]
  var action: (String) -> Void
  @State private var hovered: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(items.prefix(8), id: \.self) { word in
        Button {
          action(word)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 11))
              .foregroundStyle(Theme.text2)
            Text(word)
              .font(Theme.body())
              .lineLimit(1)
              .foregroundStyle(hovered == word ? Theme.text : Theme.text2)
            Spacer()
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in hovered = h ? word : (hovered == word ? nil : hovered) }
        .accessibilityLabel("搜索建议：\(word)")

        if word != items.prefix(8).last {
          Rectangle().fill(Theme.separator).frame(height: 1)
            .padding(.leading, 32)
        }
      }
    }
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
        .fill(Theme.card)
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    )
  }
}

// MARK: - 词条流式布局（热门搜索词等 chip 列表；自适应网格近似流式）
struct FlowChips: View {
  var items: [String]
  var action: (String) -> Void
  @State private var hovered: String?

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 88, maximum: 180), spacing: 10)],
      alignment: .leading,
      spacing: 10
    ) {
      ForEach(items, id: \.self) { word in
        Button {
          action(word)
        } label: {
          Text(word)
            .font(Theme.body())
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .foregroundStyle(hovered == word ? Theme.text : Theme.text2)
            .background(
              Capsule().fill(hovered == word ? Theme.navHover : Theme.card)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in hovered = h ? word : (hovered == word ? nil : hovered) }
        .accessibilityLabel("搜索\(word)")
      }
    }
  }
}

// MARK: - 搜索页 (SearchView)：单曲（多源聚合）/ 歌单（songlistSearch）两个 Tab
struct SearchView: View {
  @Environment(SearchService.self) private var search
  @Environment(PlayerStore.self) private var player
  @Environment(LibraryStore.self) private var library
  @Environment(DownloadStore.self) private var downloads
  @Binding var sel: SideItem

  var body: some View {
    @Bindable var search = search
    // 每轮搜索发起（session+1）与结束（searching 翻回 false）都会变 → 驱动列表滚回顶部
    let scrollToken = search.searchSession * 2 + (search.searching ? 1 : 0)
    VStack(spacing: 0) {
      modePicker
        .padding(.top, 16)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)

      switch search.searchMode {
      case .songs: songsSection(scrollToken: scrollToken)
      case .songlists: songlistsSection
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
    .onChange(of: search.searchMode) { _, _ in
      // 切 Tab 时若已有关键词立即按新模式补拉（单曲结果在提交时已就绪）
      Task {
        if search.searchMode == .songlists, !search.keyword.isEmpty, search.slResults.isEmpty {
          await search.searchSonglists(keyword: search.keyword)
        }
      }
    }
  }

  // MARK: 单曲 / 歌单 切换

  private var modePicker: some View {
    TabPillBar(
      items: SearchService.SearchMode.allCases.map { .init(id: $0, label: $0.rawValue) },
      selection: Binding(
        get: { search.searchMode },
        set: { new in Task { await search.setSearchMode(new) } }
      )
    )
    .accessibilityLabel("搜索类型")
  }

  // MARK: 热门搜索词（无关键词时展示；mg 真实热词，回退静态词）

  private var hotWordsView: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("热门搜索")
            .font(.title2.bold())
            .foregroundStyle(.white)
          if search.hotWordsLoading { ProgressView().controlSize(.small) }
          Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)

        FlowChips(items: search.hotWords) { word in
          search.clearSuggestions()
          search.keyword = word
          Task { await search.searchAll(keyword: word) }
        }
        .padding(.horizontal, 24)
      }
      .padding(.bottom, 20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .spotifyScrollbar()
    }
    .task { await search.loadHotWords() }
  }

  // MARK: 单曲结果（多源聚合）

  private func songsSection(scrollToken: Int) -> some View {
    Group {
      if search.results.isEmpty && !search.searching {
        if search.keyword.isEmpty {
          hotWordsView  // 无关键词：热门搜索词
        } else {
          EmptyStateView(
            title: "未找到相关歌曲",
            systemImage: "magnifyingglass",
            description: "尝试更换关键词，或切到「歌单」搜索"
          )
        }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("搜索结果")
              .font(.title2.bold())
              .foregroundStyle(.white)
            Text("\(search.results.count) 首")
              .font(.subheadline)
              .foregroundStyle(Theme.text2)
            Spacer()
          }
          .padding(.horizontal, 24)
          .padding(.top, 20)
          .padding(.bottom, 12)

          SongTableHeader()
            .padding(.horizontal, 16)

          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(search.results.enumerated()), id: \.element.id) { i, song in
                SongRow(song: song, queue: search.results, showIndex: i + 1)
                if i < search.results.count - 1 {
                  Rectangle()
                    .fill(Theme.separator)
                    .padding(.leading, 76)
                    .padding(.trailing, 12)
                    .frame(height: 1)
                }
              }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .spotifyScrollbar()
            // 附件挂在滚动内容里才能拿到宿主 NSScrollView；token 变化即回顶
            .scrollToTop(token: scrollToken)
          }
          .overlay {
            if search.searching {
              ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
      }
    }
  }

  // MARK: 歌单结果（来源 chips + 卡片网格，点击进歌单详情）

  private var songlistsSection: some View {
    Group {
      if search.keyword.isEmpty {
        EmptyStateView(
          title: "搜索歌单",
          systemImage: "square.grid.2x2",
          description: "在顶部搜索框输入关键词"
        )
      } else if search.slSearching && search.slResults.isEmpty {
        VStack {
          Spacer()
          ProgressView()
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if search.slResults.isEmpty {
        EmptyStateView(
          title: search.slError ?? "未找到相关歌单",
          systemImage: "square.grid.2x2",
          description: search.slError == nil ? "换个来源或关键词试试" : "点击重试",
          action: search.slError == nil ? nil : { Task { await search.searchSonglists(keyword: search.keyword) } }
        )
      } else {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("歌单结果")
              .font(.title2.bold())
              .foregroundStyle(.white)
            Text("\(search.slResults.count) 个")
              .font(.subheadline)
              .foregroundStyle(Theme.text2)
            Spacer()
            sourceChips
          }
          .padding(.horizontal, 24)
          .padding(.top, 20)

          ScrollView {
            SonglistGrid(items: search.slResults) { item in
              openSonglist(item)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .spotifyScrollbar()
          }
        }
      }
    }
  }

  /// 歌单搜索来源（kw/mg 无公开歌单接口，仅 wy/tx/kg）
  private var sourceChips: some View {
    HStack(spacing: 6) {
      ForEach(SonglistStore.searchableSources, id: \.rawValue) { src in
        let selected = search.slSourceId == src.rawValue
        Button {
          Task { await search.setSonglistSource(src.rawValue) }
        } label: {
          HStack(spacing: 4) {
            if selected {
              Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            }
            Text(SourceRegistry.capability(id: src.rawValue)?.displayName ?? src.rawValue)
          }
          .font(Theme.caption(.semibold))
          .foregroundStyle(selected ? Theme.accent : Theme.text2)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
              .fill(selected ? Theme.navHover : Theme.card)
          )
        }
        .buttonStyle(.plain)
        .help("搜索\(SourceRegistry.capability(id: src.rawValue)?.displayName ?? src.rawValue)歌单")
        .accessibilityLabel("来源：\(SourceRegistry.capability(id: src.rawValue)?.displayName ?? src.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
  }

  private func openSonglist(_ item: ALSongListItem) {
    let source = search.slSourceId
    sel = .songlistDetail(item, source: source)
  }
}

// MARK: - 正在播放
struct NowPlayingView: View {
  @Environment(PlayerStore.self) private var player
  @Environment(SearchService.self) private var search
  @Binding var sel: SideItem
  @State private var singerHovered = false

  var body: some View {
    HStack(spacing: 28) {
      // 左侧：专辑艺术
      VStack(alignment: .leading, spacing: 18) {
        CoverBig(url: player.current?.picUrl)

        VStack(alignment: .leading, spacing: 6) {
          Text(player.current?.name ?? "")
            .font(.title.bold())
            .foregroundStyle(.white)
            .lineLimit(2)

          // 点歌手 → 切到搜索页并搜该歌手（搜索框关键词同步更新）
          if let singer = player.current?.singer, !singer.isEmpty {
            Text(singer)
              .font(.title3)
              .foregroundStyle(singerHovered ? Theme.text : Theme.text2)
              .underline(singerHovered)
              .lineLimit(1)
              .onHover { singerHovered = $0 }
              .onTapGesture {
                search.keyword = singer
                sel = .search
                Task { await search.searchAll(keyword: singer) }
              }
              .help("搜索该歌手")
          }

          if let album = player.current?.albumName, !album.isEmpty {
            Text(album)
              .font(.subheadline)
              .foregroundStyle(Theme.text2.opacity(0.7))
              .lineLimit(1)
          }
        }

        Spacer()
      }
      .padding(.top, 24)
      .padding(.leading, 28)
      .frame(width: 320)

      // 右侧：歌词
      LyricView()
        .padding(.trailing, 20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
  }
}

struct CoverBig: View {
  var url: String?
  var body: some View {
    Group {
      if let u = url, let link = URL(string: u) {
        AsyncImage(url: link) { phase in
          switch phase {
          case .success(let img):
            img.resizable().aspectRatio(contentMode: .fill)
          default:
            fallback
          }
        }
      } else {
        fallback
      }
    }
    .frame(width: 260, height: 260)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
  }

  private var fallback: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(Theme.cardHover)
      .overlay(
        Image(systemName: "music.note")
          .font(.system(size: 64))
          .foregroundStyle(Theme.text2)
      )
  }
}

// MARK: - 逐字歌词流式布局（支持超长行自动换行；替代 HStack，避免逐字当前行挤压/截断）
struct FlowLayout: Layout {
  var spacing: CGFloat = 0

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var width: CGFloat = 0, height: CGFloat = 0
    var lineWidth: CGFloat = 0, lineHeight: CGFloat = 0
    for sub in subviews {
      let s = sub.sizeThatFits(.unspecified)
      if lineWidth > 0, lineWidth + spacing + s.width > maxWidth {
        height += lineHeight + spacing
        lineWidth = s.width
        lineHeight = s.height
      } else {
        lineWidth += (lineWidth == 0 ? 0 : spacing) + s.width
        lineHeight = max(lineHeight, s.height)
      }
      width = max(width, lineWidth)
    }
    height += lineHeight
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let maxWidth = bounds.width
    var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
    for sub in subviews {
      let s = sub.sizeThatFits(.unspecified)
      if x > bounds.minX, x + s.width > bounds.maxX {
        x = bounds.minX
        y += lineHeight + spacing
        lineHeight = 0
      }
      sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
      x += s.width + spacing
      lineHeight = max(lineHeight, s.height)
    }
  }
}

// MARK: - 歌词视图 (流体遮罩 + 弹性同步滚动；有 lxlyric 时当前行逐字点亮；非中文歌词带源翻译)
struct LyricView: View {
  @Environment(PlayerStore.self) private var player
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  /// 系统机翻兜底单例（观察其状态以自动刷新歌词/开关）
  private let translator = LyricTranslator.shared

  /// 解析后的原文行（有 lxlyric 走逐字，否则走普通 LRC）
  private var baseLines: [LyricLine] {
    guard let info = player.lyric else { return [] }
    if let lx = info.lxlyric, !lx.isEmpty {
      let wordLines = LrcParser.parseWordSync(lx)
      if !wordLines.isEmpty { return wordLines }
    }
    return LrcParser.parse(info.lyric)
  }

  private var lines: [LyricLine] {
    let base = baseLines
    guard showTrans else { return base }
    // 非中文歌词 + 翻译开关 → 优先源自带 tlyric，否则用系统机翻（any-listen line-player 同款时间戳对齐）
    if hasSourceTlyric, let t = player.lyric?.tlyric, !t.isEmpty {
      return LrcParser.mergeTranslation(base, t)
    }
    if let machine = translator.currentCached, !machine.isEmpty {
      return LrcParser.mergeTranslation(base, machine)
    }
    return base
  }
  private var idx: Int? { LrcParser.index(at: player.currentTime, in: lines) }

  /// 源是否自带翻译（wy/tx/kw/mg 的 tlyric；kg 无）
  private var hasSourceTlyric: Bool {
    let t = player.lyric?.tlyric ?? ""
    return !t.isEmpty
  }
  /// 原文是否中文歌词（中文歌显示翻译没有意义）
  private var isChineseOriginal: Bool {
    guard let info = player.lyric else { return true }
    return LrcParser.isChinese([info.lxlyric, info.lyric].compactMap { $0 }.joined())
  }
  /// 翻译当前是否生效（开关开 + 非中文 + 有来源翻译或机翻已可用）
  private var showTrans: Bool {
    player.showTranslation && !isChineseOriginal && (hasSourceTlyric || translator.available)
  }
  /// 翻译是否可能（非中文 + 有源翻译或机翻可用）——用于开关按钮显隐
  private var translationPossible: Bool {
    !isChineseOriginal && (hasSourceTlyric || translator.available)
  }

  var body: some View {
    let parsedLines = lines
    let currentIdx = idx

    ScrollViewReader { proxy in
      ScrollView(showsIndicators: false) {
        LazyVStack(alignment: .leading, spacing: 14) {
          if parsedLines.isEmpty {
            Text(player.lyric?.lyric ?? "暂无歌词")
              .font(.title3)
              .foregroundStyle(Theme.text2)
              .padding(.vertical, 60)
              .textSelection(.enabled)
          } else {
            Color.clear.frame(height: 120) // 顶部留白

            ForEach(parsedLines.indices, id: \.self) { i in
              let isCurrent = (i == currentIdx)
              lyricLine(parsedLines[i], isCurrent: isCurrent)
                .id(i)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentIdx)
                .onTapGesture {
                  player.seek(parsedLines[i].time / max(player.duration, 1.0))
                }
            }

            Color.clear.frame(height: 160) // 底部留白
          }
        }
        .padding(.horizontal, 24)
      }
      .mask {
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.88),
            .init(color: .clear, location: 1.0)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      .overlay(alignment: .topTrailing) {
        if translationPossible {
          translationToggle
            .padding(.top, 8)
            .padding(.trailing, 4)
        }
      }
      .onChange(of: currentIdx) { _, newIdx in
        guard let newIdx, !reduceMotion else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
          proxy.scrollTo(newIdx, anchor: .center)
        }
      }
      // 歌词/歌曲变化 → 无源翻译且非中文时触发系统机翻（幂等，完成后自动刷新）
      .task(id: player.current?.id ?? "") {
        let songID = player.current?.id ?? ""
        guard !songID.isEmpty else { return }
        await translator.ensureTranslation(songID: songID, base: baseLines, hasSourceTlyric: hasSourceTlyric)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// 翻译开关（仅翻译可能时出现；状态持久化 lyric.showTranslation；机翻进行中显示进度）
  private var translationToggle: some View {
    Button {
      player.showTranslation.toggle()
    } label: {
      Group {
        if translator.isTranslating && !hasSourceTlyric {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "translate")
            .font(.system(size: 11, weight: .semibold))
        }
      }
      .foregroundStyle(player.showTranslation ? Theme.accent : Theme.text2.opacity(0.45))
      .frame(width: 24, height: 24)
      .background(Circle().fill(Theme.card.opacity(0.9)))
    }
    .buttonStyle(.plain)
    .help(player.showTranslation ? "隐藏中文翻译" : "显示中文翻译")
    .accessibilityLabel(player.showTranslation ? "隐藏中文翻译" : "显示中文翻译")
  }

  /// 行渲染：当前行且有词段 → 逐字点亮（已唱全亮、未唱半透明）；其余行纯文本；翻译小字随行。
  /// 当前行逐字用 FlowLayout（超长行自动换行，避免 HStack 挤压/截断）
  @ViewBuilder private func lyricLine(_ line: LyricLine, isCurrent: Bool) -> some View {
    if isCurrent, let words = line.words, !words.isEmpty {
      VStack(alignment: .leading, spacing: 5) {
        FlowLayout(spacing: 0) {
          let lineStart = line.time
          ForEach(Array(words.enumerated()), id: \.offset) { _, word in
            let wordTime = lineStart + word.start
            let sung = player.currentTime >= wordTime
            Text(word.text)
              .font(.system(size: 24, weight: .bold))
              .foregroundStyle(sung ? Color.white : Color.white.opacity(0.42))
              .onTapGesture {
                player.seek(wordTime / max(player.duration, 1.0))
              }
          }
        }
        if let trans = line.translation, !trans.isEmpty {
          Text(trans)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.7))
        }
      }
      .scaleEffect(1.03, anchor: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(line.translation.map { "\(line.text)，\($0)" } ?? line.text)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Text(line.text)
          .font(isCurrent ? .system(size: 24, weight: .bold) : .system(size: 16, weight: .medium))
          .foregroundStyle(isCurrent ? Color.white : Theme.text2.opacity(0.55))
        if let trans = line.translation, !trans.isEmpty {
          Text(trans)
            .font(isCurrent ? .system(size: 14, weight: .semibold) : .system(size: 13, weight: .medium))
            .foregroundStyle(isCurrent ? Color.white.opacity(0.7) : Theme.text2.opacity(0.38))
        }
      }
      .scaleEffect(isCurrent ? 1.03 : 1.0, anchor: .leading)
    }
  }
}

// MARK: - 歌单 / 历史 / 下载视图
struct PlaylistView: View {
  @Environment(LibraryStore.self) private var library
  @Environment(PlayerStore.self) private var player
  @Environment(DownloadStore.self) private var downloads
  var playlistId: String
  @State private var newName = ""
  @State private var renaming = false

  var body: some View {
    if let pl = library.playlists.first(where: { $0.id == playlistId }) {
      VStack(spacing: 0) {
        HStack(alignment: .center, spacing: 16) {
          if let cover = pl.songs.first?.picUrl {
            CoverThumb(url: cover, size: 96, cornerRadius: 6)
              .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
          } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.cardHover], startPoint: .topLeading, endPoint: .bottomTrailing))
              .frame(width: 96, height: 96)
              .overlay {
                Image(systemName: playlistId == "fav" ? "heart.fill" : "music.note.list")
                  .font(.system(size: 32))
                  .foregroundStyle(.white.opacity(0.9))
              }
          }

          VStack(alignment: .leading, spacing: 3) {
            Text(pl.name)
              .font(Theme.display())
              .foregroundStyle(Theme.text)
            Text("\(pl.songs.count) 首")
              .font(Theme.body())
              .foregroundStyle(Theme.text2)
          }

          Spacer()

          PlayAllButton(count: pl.songs.count, action: playAll)

          if playlistId != "fav" {
            VStack(spacing: 8) {
              Button("重命名") { renaming = true }
                .controlSize(.small)
              Button("删除歌单", role: .destructive) { library.deletePlaylist(playlistId) }
                .controlSize(.small)
            }
          }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .background(
          LinearGradient(
            colors: [Theme.cardHover.opacity(0.55), Theme.bg],
            startPoint: .top,
            endPoint: .bottom
          )
        )

        if pl.songs.isEmpty {
          EmptyStateView(
            title: "歌单为空",
            systemImage: "music.note.list",
            description: "从搜索结果或推荐榜单右键添加歌曲"
          )
        } else {
          SongTableHeader()
            .padding(.horizontal, 16)
            .padding(.top, 8)

          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(pl.songs.enumerated()), id: \.element.id) { i, song in
                SongRow(song: song, queue: pl.songs, playlistId: playlistId, showIndex: i + 1)
                if i < pl.songs.count - 1 {
                  Rectangle()
                    .fill(Theme.separator)
                    .padding(.leading, 76)
                    .padding(.trailing, 12)
                    .frame(height: 1)
                }
              }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .spotifyScrollbar()
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Theme.bg)
      .alert("重命名", isPresented: $renaming) {
        TextField("歌单名", text: $newName)
        Button("确定") { if !newName.isEmpty { library.renamePlaylist(playlistId, newName) } }
        Button("取消", role: .cancel) {}
      }
    } else {
      EmptyStateView(
        title: "歌单不存在",
        systemImage: "exclamationmark.triangle",
        description: ""
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Theme.bg)
    }
  }

  private func playAll() {
    guard let songs = library.playlists.first(where: { $0.id == playlistId })?.songs,
          let first = songs.first else { return }
    player.play(first, in: songs)
  }
}

struct HistoryView: View {
  @Environment(LibraryStore.self) private var library
  @Environment(PlayerStore.self) private var player

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("最近播放")
          .font(.title2.bold())
          .foregroundStyle(.white)
        Spacer()
        if !library.history.isEmpty {
          PlayAllButton(count: library.history.count, action: playAll)
          Button("清空历史", role: .destructive) { library.history.removeAll() }
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 12)

      if library.history.isEmpty {
        EmptyStateView(
          title: "暂无播放历史",
          systemImage: "clock",
          description: "播放过的歌曲将自动记录于此"
        )
      } else {
        SongTableHeader()
          .padding(.horizontal, 16)

        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(library.history.enumerated()), id: \.element.id) { i, song in
              SongRow(song: song, queue: library.history, showIndex: i + 1)
              if i < library.history.count - 1 {
                Rectangle()
                  .fill(Theme.separator)
                  .padding(.leading, 76)
                  .padding(.trailing, 12)
                  .frame(height: 1)
              }
            }
          }
          .padding(.vertical, 6)
          .padding(.horizontal, 8)
          .spotifyScrollbar()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
  }

  private func playAll() {
    guard let first = library.history.first else { return }
    player.play(first, in: library.history)
  }
}

struct DownloadsView: View {
  @Environment(DownloadStore.self) private var downloads

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("下载管理")
          .font(.title2.bold())
          .foregroundStyle(.white)
        Spacer()
        Text("~/Music/iMusic")
          .font(.caption)
          .foregroundStyle(Theme.text2)
          .textSelection(.enabled)
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 12)

      if downloads.tasks.isEmpty {
        EmptyStateView(
          title: "暂无下载任务",
          systemImage: "arrow.down.circle",
          description: "可在歌曲右键菜单中选择「下载」"
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(downloads.tasks) { t in
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                  Text("\(t.song.name) - \(t.song.singer)")
                    .foregroundStyle(.white)
                    .lineLimit(1)
                  Text(t.state)
                    .font(.caption)
                    .foregroundStyle(Theme.text2)
                }
                Spacer()
                ProgressView(value: t.progress)
                  .tint(Theme.accent)
                  .frame(width: 140)
                if t.progress < 1, t.state.hasPrefix("下载中") {
                  Button("取消", role: .destructive) { downloads.cancel(t.id) }
                    .controlSize(.small)
                }
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .fill(Theme.card)
              )
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .spotifyScrollbar()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
  }
}
