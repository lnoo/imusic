import SwiftUI
import Observation

// MARK: - Spotify 深色 UI：纯黑侧栏 / #121212 内容区 / 全宽底部播放条

// MARK: - 空状态视图
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

enum SideItem: Hashable {
  case home, search, nowPlaying, history, downloads, source
  case playlist(String)
  case board(String)
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
    .alert("源有更新", isPresented: .constant(state.api.updateAlert != nil)) {
      Button("稍后") { state.api.updateAlert = nil }
      if let u = state.api.updateAlert?.updateUrl, let url = URL(string: u) {
        Button("查看更新") {
          NSWorkspace.shared.open(url)
          state.api.updateAlert = nil
        }
      }
    } message: {
      Text(state.api.updateAlert?.log ?? "")
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
            .textFieldStyle(.plain)
            .frame(width: 220)
            .onSubmit {
              let kw = search.keyword
              sel = .search
              Task { await search.searchAll(keyword: kw) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .fill(Theme.field)
        )
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
    case .search: SearchView()
    case .nowPlaying: NowPlayingView()
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

          Text(player.current?.singer ?? "")
            .font(Theme.caption())
            .foregroundStyle(Theme.text2)
            .lineLimit(1)
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
            Image(systemName: player.playbackState == .failed ? "arrow.clockwise" : player.isPlaying ? "pause.fill" : "play.fill")
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
          .help(player.playbackState == .failed ? "重试播放" : player.isPlaying ? "暂停" : "播放")
          .accessibilityLabel(player.playbackState == .failed ? "重试播放" : player.isPlaying ? "暂停" : "播放")

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
        Button(library.disliked.contains(song.id) ? "取消不喜欢" : "不喜欢") { library.toggleDislike(song) }
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
      Button(library.disliked.contains(song.id) ? "取消不喜欢" : "不喜欢") { library.toggleDislike(song) }
    }
  }

  private var isLiked: Bool {
    library.playlists.first(where: { $0.id == "fav" })?.songs.contains(where: { $0.id == song.id }) ?? false
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

// MARK: - 搜索页 (SearchView)
struct SearchView: View {
  @Environment(SearchService.self) private var search
  @Environment(PlayerStore.self) private var player
  @Environment(LibraryStore.self) private var library
  @Environment(DownloadStore.self) private var downloads

  var body: some View {
    VStack(spacing: 0) {
      if search.results.isEmpty && !search.searching {
        EmptyStateView(
          title: search.keyword.isEmpty ? "搜索歌曲" : "未找到相关歌曲",
          systemImage: "magnifyingglass",
          description: search.keyword.isEmpty ? "输入关键词开始搜索" : "尝试更换关键词"
        )
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
  }
}

// MARK: - 正在播放
struct NowPlayingView: View {
  @Environment(PlayerStore.self) private var player

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

          Text(player.current?.singer ?? "")
            .font(.title3)
            .foregroundStyle(Theme.text2)
            .lineLimit(1)

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

// MARK: - 歌词视图 (流体遮罩 + 弹性同步滚动)
struct LyricView: View {
  @Environment(PlayerStore.self) private var player
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  private var lines: [LyricLine] { player.lyric.map { LrcParser.parse($0.lyric) } ?? [] }
  private var idx: Int? { LrcParser.index(at: player.currentTime, in: lines) }

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
              Text(parsedLines[i].text)
                .font(isCurrent ? .system(size: 24, weight: .bold) : .system(size: 16, weight: .medium))
                .foregroundStyle(isCurrent ? Color.white : Theme.text2.opacity(0.55))
                .scaleEffect(isCurrent ? 1.03 : 1.0, anchor: .leading)
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
      .onChange(of: currentIdx) { _, newIdx in
        guard let newIdx, !reduceMotion else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
          proxy.scrollTo(newIdx, anchor: .center)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
