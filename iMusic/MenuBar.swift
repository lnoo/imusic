import SwiftUI
import AppKit

// MARK: - 顶部菜单栏（MenuBarExtra）
// 图标态：无曲目=音符；播放中=播放符+暂停点；已暂停=播放符
// 点击展开：曲目信息 + 上一首/暂停/下一首 + 进度 + 打开主界面/退出

struct MenuBarLabel: View {
  @Environment(PlayerStore.self) private var player

  var body: some View {
    Image(systemName: symbolName)
      .symbolRenderingMode(.hierarchical)
      .accessibilityLabel(accessibilityLabel)
  }

  private var symbolName: String {
    guard player.current != nil else { return "music.note" }
    switch player.playbackState {
    case .idle:
      return "play.circle.fill"
    case .loading:
      return "hourglass"
    case .ready:
      return player.isPlaying ? "pause.circle.fill" : "play.circle.fill"
    case .failed:
      return "exclamationmark.circle.fill"
    }
  }

  private var accessibilityLabel: String {
    guard let name = player.current?.name else { return "iMusic，未在播放" }
    switch player.playbackState {
    case .idle:
      return "iMusic，\(name)"
    case .loading:
      return "iMusic，正在加载 \(name)"
    case .ready:
      return "iMusic，\(player.isPlaying ? "正在播放" : "已暂停") \(name)"
    case .failed:
      return "iMusic，\(name) 播放失败"
    }
  }
}

struct MenuBarView: View {
  @Environment(PlayerStore.self) private var player
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss
  @State private var isDraggingSlider = false
  @State private var dragProgress: Double = 0
  @State private var pendingSeekTask: Task<Void, Never>?

  private var displayedCurrentTime: Double {
    guard player.duration.isFinite, player.duration > 0 else { return 0 }
    return isDraggingSlider ? player.duration * dragProgress : player.currentTime
  }

  private var trackSubtitle: String {
    guard player.current != nil else { return "从主界面选择歌曲" }
    switch player.playbackState {
    case .loading, .failed:
      return player.status
    case .idle, .ready:
      return player.current?.singer ?? ""
    }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      trackHeader

      if player.canSeek {
        progressSection
      }

      controlRow

      Divider()
        .overlay(Theme.separator)

      footer
    }
    .padding(14)
    .frame(width: 300)
    .background(Theme.bg)
    .foregroundStyle(Theme.text)
    .preferredColorScheme(.dark)
    .tint(Theme.accent)
    .onChange(of: player.current?.id) { _, _ in
      resetSlider()
    }
    .onDisappear {
      pendingSeekTask?.cancel()
      isDraggingSlider = false
    }
  }

  private var trackHeader: some View {
    HStack(spacing: 10) {
      CoverThumb(url: player.current?.picUrl, size: 44, cornerRadius: 8)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(player.current?.name ?? "未在播放")
          .font(Theme.body(.semibold))
          .lineLimit(1)

        Text(trackSubtitle)
          .font(Theme.caption())
          .foregroundStyle(Theme.text2)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)

      Spacer(minLength: 0)
    }
  }

  private var progressSection: some View {
    VStack(spacing: 4) {
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
      .accessibilityLabel("播放进度")
      .accessibilityValue("\(formatTime(displayedCurrentTime))，总时长 \(formatTime(player.duration))")

      HStack {
        Text(formatTime(displayedCurrentTime))
        Spacer()
        Text(formatTime(player.duration))
      }
      .font(Theme.monoCaption())
      .foregroundStyle(Theme.text2)
      .accessibilityHidden(true)
    }
  }

  private var controlRow: some View {
    HStack(spacing: 10) {
      Spacer()

      Button {
        player.prev()
      } label: {
        Image(systemName: "backward.fill")
          .frame(width: 28, height: 22)
      }
      .buttonStyle(.borderless)
      .disabled(!player.canGoPrevious)
      .help("上一首")
      .accessibilityLabel("上一首")

      Button {
        player.toggle()
      } label: {
        Image(systemName: playbackSymbolName)
          .font(.system(size: 13, weight: .bold))
          .frame(width: 36, height: 26)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(!player.canTogglePlayback)
      .help(playbackHelp)
      .accessibilityLabel(playbackHelp)

      Button {
        player.next()
      } label: {
        Image(systemName: "forward.fill")
          .frame(width: 28, height: 22)
      }
      .buttonStyle(.borderless)
      .disabled(!player.canGoNext)
      .help("下一首")
      .accessibilityLabel("下一首")

      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var playbackSymbolName: String {
    if player.playbackState == .failed { return "arrow.clockwise" }
    return player.isPlaying ? "pause.fill" : "play.fill"
  }

  private var playbackHelp: String {
    if player.playbackState == .loading { return "正在加载" }
    if player.playbackState == .failed { return "重试播放" }
    return player.isPlaying ? "暂停" : "播放"
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button {
        player.cycleMode()
      } label: {
        Label(player.mode.rawValue, systemImage: player.modeIcon)
          .font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .help("播放模式：\(player.mode.rawValue)")
      .accessibilityLabel("播放模式，\(player.mode.rawValue)")

      Spacer()

      Button("主界面") {
        openMainWindow()
      }
      .buttonStyle(.borderless)
      .font(.system(size: 11))

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Image(systemName: "power")
          .font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .help("退出 iMusic")
      .accessibilityLabel("退出 iMusic")
    }
  }

  private func openMainWindow() {
    NSApp.activate()
    openWindow(id: "main")
    dismiss()
  }
}
