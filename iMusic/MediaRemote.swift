import Foundation
import MediaPlayer
import AppKit
import Observation

// MARK: - MediaRemoteController
// 系统远程播放命令接管（耳机/媒体键 → PlayerStore）：
//   AirPods 双击/捏合手势在「系统设置 → 蓝牙 → AirPods」里被映射为 上一首/下一首/播放暂停，
//   macOS 把它们作为 MPRemoteCommand 分发给"正在播放"的 App；本层注册 MPRemoteCommandCenter
//   接住命令并转发到 PlayerStore（控制中心、菜单栏媒体键、耳机手势同一条链路）。
// 同时用 MPNowPlayingInfoCenter 同步 曲目/歌手/封面/进度/播放态，
//   让控制中心显示 iMusic 与当前歌曲——这也是系统把命令路由给 iMusic 的依据。
// 并发：handler 可能在任意线程到达，统一经 run(_:_:) hop 到 MainActor（isMainThread 快路径
//   + 否则 main.sync），避免 Swift 6 严格并发下跨线程访问 @MainActor PlayerStore。
//
// ⚠ 隔离陷阱（曾致播放即崩，勿回退）：闭包若在 @MainActor 方法里"字面形成"且形参类型未标注隔离，
//   类型检查放行但会被隐式推断成 @MainActor 隔离；MediaPlayer 随后在 */accessQueue 后台队列
//   调它（artwork 取图）→ _swift_task_checkIsolatedSwift 断言 → SIGTRAP。
//   因此所有"交给系统、可能在非主线程回调"的闭包（artwork handler / addTarget 回调）
//   必须经下方 nonisolated 工厂形成，让闭包成为非隔离闭包。
@MainActor
final class MediaRemoteController {
  static let shared = MediaRemoteController()

  private weak var player: PlayerStore?
  /// (命令, addTarget 返回的 token)，teardown 时逐一 removeTarget
  private var targets: [(command: MPRemoteCommand, token: Any)] = []
  /// 同名命令去重窗口（系统偶发重复投递一次事件；0.15s 内同键只认第一次）
  private var lastFire: [String: Double] = [:]

  private var coverURLString: String?
  private var coverImage: NSImage?
  private var coverTask: Task<Void, Never>?

  // MARK: 接线

  /// 注册全部远程命令并开始同步"正在播放"信息（幂等；AppState 启动时调用一次）
  func attach(to player: PlayerStore) {
    guard targets.isEmpty else { return }
    self.player = player
    let center = MPRemoteCommandCenter.shared()

    func reg(_ command: MPRemoteCommand, _ name: String,
             _ work: @escaping @MainActor () -> MPRemoteCommandHandlerStatus) {
      command.isEnabled = true
      targets.append((command, command.addTarget(handler: makeHandler(name, work))))
    }

    reg(center.playCommand, "play") { [weak self] in self?.play() ?? .commandFailed }
    reg(center.pauseCommand, "pause") { [weak self] in self?.pause() ?? .commandFailed }
    reg(center.stopCommand, "stop") { [weak self] in self?.pause() ?? .commandFailed }
    reg(center.togglePlayPauseCommand, "toggle") { [weak self] in self?.toggle() ?? .commandFailed }
    reg(center.nextTrackCommand, "next") { [weak self] in self?.next() ?? .commandFailed }
    reg(center.previousTrackCommand, "prev") { [weak self] in self?.prev() ?? .commandFailed }
    // 控制中心拖动进度条 / 锁屏进度条（positionTime 在非隔离上下文取出，跨隔离只传 Double）
    targets.append((center.changePlaybackPositionCommand,
                    center.changePlaybackPositionCommand.addTarget(handler: makeSeekHandler())))

    armObservation()
    pushNowPlaying()
  }

  // MARK: 非隔离闭包工厂（见文件头「隔离陷阱」：这些闭包必须在 nonisolated 上下文形成）

  /// 系统命令回调：非隔离闭包，内部经 run(_:_:) hop 回主线程执行 work（work 为 @MainActor）。
  nonisolated private func makeHandler(_ name: String,
                                      _ work: @escaping @MainActor () -> MPRemoteCommandHandlerStatus)
    -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    return { [weak self] _ in
      guard let self else { return .commandFailed }
      return self.run(name, work)
    }
  }

  /// seek 回调：先把 positionTime（Double）取出，再 hop 进主线程 seek。
  nonisolated private func makeSeekHandler()
    -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    return { [weak self] event in
      guard let self,
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
      return self.run("seek") { [weak self] in
        guard let self, let player = self.player else { return .commandFailed }
        guard player.canSeek, player.duration.isFinite, player.duration > 0 else { return .noSuchContent }
        player.seek(position / player.duration)
        return .success
      }
    }
  }

  /// artwork 取图闭包：MediaPlayer 会在 */accessQueue 后台队列调用，必须非隔离。
  nonisolated private static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }

  /// 移除全部命令并清空"正在播放"信息
  func teardown() {
    coverTask?.cancel()
    coverTask = nil
    for target in targets {
      target.command.removeTarget(target.token)
    }
    targets.removeAll()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    player = nil
  }

  // MARK: 命令执行（handler → MainActor）

  /// 去重 + 线程 hop：handler 可能不在主线程；主线程直接 assumeIsolated，否则同步 hop。
  private nonisolated func run(_ name: String,
                               _ work: @escaping @MainActor () -> MPRemoteCommandHandlerStatus)
    -> MPRemoteCommandHandlerStatus {
    if Thread.isMainThread {
      return MainActor.assumeIsolated { fire(name, work) }
    }
    return DispatchQueue.main.sync { MainActor.assumeIsolated { fire(name, work) } }
  }

  private func fire(_ name: String,
                    _ work: () -> MPRemoteCommandHandlerStatus) -> MPRemoteCommandHandlerStatus {
    let now = ProcessInfo.processInfo.systemUptime
    if let last = lastFire[name], now - last < 0.15 { return .success }
    lastFire[name] = now
    return work()
  }

  private func play() -> MPRemoteCommandHandlerStatus {
    guard let player, player.current != nil else { return .noActionableNowPlayingItem }
    guard player.canTogglePlayback else { return .noSuchContent }
    player.togglePlay(true)
    return .success
  }

  private func pause() -> MPRemoteCommandHandlerStatus {
    guard let player, player.current != nil else { return .noActionableNowPlayingItem }
    player.togglePlay(false)
    return .success
  }

  private func toggle() -> MPRemoteCommandHandlerStatus {
    guard let player, player.current != nil else { return .noActionableNowPlayingItem }
    guard player.canTogglePlayback else { return .noSuchContent }
    player.toggle()
    return .success
  }

  private func next() -> MPRemoteCommandHandlerStatus {
    guard let player, player.current != nil else { return .noActionableNowPlayingItem }
    guard player.canGoNext else { return .noSuchContent }
    player.next()
    return .success
  }

  private func prev() -> MPRemoteCommandHandlerStatus {
    guard let player, player.current != nil else { return .noActionableNowPlayingItem }
    guard player.canGoPrevious else { return .noSuchContent }
    player.prev()
    return .success
  }

  // MARK: 正在播放信息同步

  /// 把当前曲目/进度/播放态推给系统（控制中心、耳机面板）。
  /// 由 Observation 回调驱动：曲目、播放态、进度任一变化都会触发。
  private func pushNowPlaying() {
    let center = MPNowPlayingInfoCenter.default()
    guard let player, let song = player.current else {
      center.nowPlayingInfo = nil
      center.playbackState = .stopped
      return
    }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: song.name,
      MPMediaItemPropertyArtist: song.singer,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
      MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
    ]
    if !song.albumName.isEmpty {
      info[MPMediaItemPropertyAlbumTitle] = song.albumName
    }
    if player.duration.isFinite, player.duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = player.duration
    }
    if let image = coverImage, image.size.width > 0, image.size.height > 0 {
      info[MPMediaItemPropertyArtwork] = Self.makeArtwork(image)
    }
    center.nowPlayingInfo = info
    center.playbackState = player.isPlaying ? .playing : .paused
    loadCoverIfNeeded(song)
  }

  /// 读 player 的可观察属性并注册一次性 onChange 回调；回调里推送后重新武装。
  /// （withObservationTracking 每次只触发一次，必须自续）
  private func armObservation() {
    guard let player else { return }
    withObservationTracking {
      _ = player.current
      _ = player.isPlaying
      _ = player.currentTime
      _ = player.duration
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.pushNowPlaying()
        self?.armObservation()
      }
    }
  }

  /// 封面异步拉取（同曲只拉一次；旧任务按曲目 token 取消，防止串图）
  private func loadCoverIfNeeded(_ song: MusicInfo) {
    guard song.picUrl != coverURLString else { return }
    coverURLString = song.picUrl
    coverImage = nil
    coverTask?.cancel()
    guard let raw = song.picUrl, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return }
    let token = song.id
    coverTask = Task { [weak self] in
      guard let (data, _) = try? await URLSession.shared.data(from: url),
            let image = NSImage(data: data) else { return }
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self, let current = self.player?.current, current.id == token else { return }
        self.coverImage = image
        self.pushNowPlaying()
      }
    }
  }
}
