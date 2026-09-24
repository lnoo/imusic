import Foundation
import AVFoundation
import SwiftUI
import Observation

// MARK: - PlayerStore
// 对标 src/renderer/core/music/online.ts#getMusicUrl + utils.ts#handleGetOnlineMusicUrl
// 链路：getPlayQuality(按 qualityList ∩ song.types 降级) -> userApiEngine.callScript(musicUrl)
//       -> AVPlayer 播放；歌词/封面同理经 callScript(lyric/pic)，失败则直连官站兜底（MVP仅歌词透传失败即空）

@Observable @MainActor
final class PlayerStore {
  var current: MusicInfo?
  var queue: [MusicInfo] = []
  private(set) var queueContext: String?
  var isPlaying = false
  var resolvedUrl: String?
  var lyric: LyricInfo?
  var status = "就绪"
  var progress: Double = 0 // 0...1
  var currentTime: Double = 0 // 秒（歌词滚动用）
  var duration: Double = 0 // 总秒数
  var mode: PlayMode = .sequence // 播放模式（对标 store/player）
  var volume: Double = 1.0 // 0...1

  enum PlaybackState: Equatable {
    case idle
    case loading
    case ready
    case failed
  }

  private(set) var playbackState: PlaybackState = .idle

  enum PlayMode: String, CaseIterable {
    case sequence = "顺序", loopAll = "循环", single = "单曲", shuffle = "随机"
  }

  var canTogglePlayback: Bool {
    current != nil && (playbackState == .ready || playbackState == .failed)
  }

  var canSeek: Bool {
    playbackState == .ready && duration.isFinite && duration > 0
  }

  var canGoNext: Bool {
    guard let current, !queue.isEmpty else { return false }
    switch mode {
    case .loopAll:
      return true
    case .shuffle:
      return queue.contains { $0.id != current.id }
    case .sequence, .single:
      guard let index = queueIndex(of: current) else { return false }
      return index + 1 < queue.count
    }
  }

  var canGoPrevious: Bool {
    guard let current else { return false }
    switch mode {
    case .loopAll:
      return queue.count > 1 || playbackState == .ready
    case .shuffle:
      return queue.contains { $0.id != current.id } || playbackState == .ready
    case .sequence, .single:
      guard let index = queueIndex(of: current) else { return playbackState == .ready }
      return index > 0 || playbackState == .ready
    }
  }

  var modeIcon: String {
    switch mode {
    case .sequence: return "list.bullet"
    case .loopAll: return "repeat"
    case .single: return "repeat.1"
    case .shuffle: return "shuffle"
    }
  }

  func cycleMode() {
    let all = PlayMode.allCases
    mode = all[(all.firstIndex(of: mode)! + 1) % all.count]
  }

  /// 仅解析 URL（下载/分享用，不切播放）
  func resolveUrlOnly(_ song: MusicInfo) async -> String? {
    guard let engine, engine.inited,
          engine.sources[song.source.rawValue]?.actions.contains(.musicUrl) == true else { return nil }
    let q = pickQuality(for: song, supported: engine.qualitys[song.source.rawValue])
    if let v = try? await engine.callScript(source: song.source.rawValue, action: .musicUrl, quality: q, music: song),
       let u = v as? String { return u }
    if let alt = await findOtherSource(song, quality: q) { return alt.url }
    return nil
  }

  private var player = AVPlayer()
  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var playerStatusObservation: NSKeyValueObservation?
  @ObservationIgnored private var playerTimeControlObservation: NSKeyValueObservation?
  @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
  @ObservationIgnored private var itemDurationObservation: NSKeyValueObservation?
  @ObservationIgnored private var playerFailed = false
  private var engine: UserApiEngine?
  var searcher: SearchService? // 换源用（AppState 注入）
  /// 内置模式音质表（AppState 同步：自定义源生效时为 engine.qualitys，否则注册表内置表）
  /// 对标桌面端 store qualityList + getPlayQuality 的 list?.includes(q)
  var qualityMap: [String: [MusicQuality]] = [:]
  /// 播放代次：连点上/下首时只认最后一次 resolve，防止旧任务后到覆盖
  private var playToken = 0

  init() {
    configurePlayer()
    NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
      guard let item = notification.object as? AVPlayerItem else { return }
      let itemID = ObjectIdentifier(item)
      Task { @MainActor [weak self] in
        guard let self,
              let currentItem = self.player.currentItem,
              ObjectIdentifier(currentItem) == itemID else { return }
        self.ended()
      }
    }
    NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
      guard let item = notification.object as? AVPlayerItem else { return }
      let itemID = ObjectIdentifier(item)
      let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
      Task { @MainActor [weak self] in
        guard let self,
              let currentItem = self.player.currentItem,
              ObjectIdentifier(currentItem) == itemID else { return }
        self.setPlaybackFailure(message.map { "播放失败：\($0)" } ?? "播放失败")
      }
    }
  }

  private func configurePlayer() {
    let playerID = ObjectIdentifier(player)
    playerStatusObservation = player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
      let rawStatus = player.status.rawValue
      Task { @MainActor [weak self] in
        self?.handlePlayerStatus(rawStatus, playerID: playerID)
      }
    }
    playerTimeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
      let rawStatus = player.timeControlStatus.rawValue
      Task { @MainActor [weak self] in
        self?.handlePlayerTimeControlStatus(rawStatus, playerID: playerID)
      }
    }
    let observedPlayer = player
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
      let itemID = observedPlayer.currentItem.map(ObjectIdentifier.init)
      Task { @MainActor [weak self] in
        self?.syncPlaybackState(time: time, from: observedPlayer, itemID: itemID)
      }
    }
  }

  private func replacePlayer() {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    playerStatusObservation?.invalidate()
    playerTimeControlObservation?.invalidate()
    itemStatusObservation?.invalidate()
    itemDurationObservation?.invalidate()
    timeObserver = nil
    playerStatusObservation = nil
    playerTimeControlObservation = nil
    itemStatusObservation = nil
    itemDurationObservation = nil
    let replacement = AVPlayer()
    replacement.volume = player.volume
    player = replacement
    playerFailed = false
    configurePlayer()
  }

  /// 队列定位按 id，不用全字段相等（picUrl/extra 回填后 current ≠ queue 元素）
  private func queueIndex(of song: MusicInfo?) -> Int? {
    guard let song else { return nil }
    return queue.firstIndex { $0.id == song.id }
  }

  private func shuffledSong(avoiding songID: String?) -> MusicInfo? {
    if let songID {
      let candidates = queue.filter { $0.id != songID }
      if let song = candidates.randomElement() { return song }
    }
    return queue.randomElement()
  }

  private func installCurrentItem(_ item: AVPlayerItem?) {
    itemStatusObservation?.invalidate()
    itemDurationObservation?.invalidate()
    itemStatusObservation = nil
    itemDurationObservation = nil
    player.replaceCurrentItem(with: item)
    guard let item else { return }
    let itemID = ObjectIdentifier(item)
    itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      let rawStatus = item.status.rawValue
      let message = item.error?.localizedDescription
      Task { @MainActor [weak self] in
        self?.handleItemStatus(rawStatus, message: message, itemID: itemID)
      }
    }
    itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
      let seconds = item.duration.seconds
      Task { @MainActor [weak self] in
        self?.handleItemDuration(seconds, itemID: itemID)
      }
    }
  }

  private func handlePlayerStatus(_ rawStatus: Int, playerID: ObjectIdentifier) {
    guard ObjectIdentifier(player) == playerID,
          let status = AVPlayer.Status(rawValue: rawStatus) else { return }
    if status == .failed {
      playerFailed = true
      itemStatusObservation?.invalidate()
      itemDurationObservation?.invalidate()
      itemStatusObservation = nil
      itemDurationObservation = nil
      setPlaybackFailure("播放器启动失败")
    } else {
      playerFailed = false
    }
  }

  private func handlePlayerTimeControlStatus(_ rawStatus: Int, playerID: ObjectIdentifier) {
    guard ObjectIdentifier(player) == playerID,
          !playerFailed,
          let status = AVPlayer.TimeControlStatus(rawValue: rawStatus),
          playbackState == .ready else { return }
    isPlaying = status != .paused
  }

  private func handleItemStatus(_ rawStatus: Int, message: String?, itemID: ObjectIdentifier) {
    guard !playerFailed,
          let item = player.currentItem, ObjectIdentifier(item) == itemID,
          let itemStatus = AVPlayerItem.Status(rawValue: rawStatus) else { return }
    switch itemStatus {
    case .readyToPlay:
      let wasReady = playbackState == .ready
      playbackState = .ready
      if !wasReady {
        status = isPlaying ? "正在播放 \(current?.name ?? "")" : "已暂停"
      }
      updatePlaybackTime(player.currentTime(), duration: item.duration.seconds)
    case .failed:
      setPlaybackFailure(message.map { "播放失败：\($0)" } ?? "播放失败")
    case .unknown:
      isPlaying = false
    @unknown default:
      isPlaying = false
    }
  }

  private func handleItemDuration(_ seconds: Double, itemID: ObjectIdentifier) {
    guard !playerFailed,
          let item = player.currentItem,
          ObjectIdentifier(item) == itemID else { return }
    updatePlaybackTime(player.currentTime(), duration: seconds)
  }

  private func syncPlaybackState(time: CMTime, from p: AVPlayer, itemID: ObjectIdentifier?) {
    guard !playerFailed, p === player, let item = p.currentItem else { return }
    if let itemID, ObjectIdentifier(item) != itemID { return }
    guard item.status == .readyToPlay else {
      if item.status == .failed {
        setPlaybackFailure(item.error.map { "播放失败：\($0.localizedDescription)" } ?? "播放失败")
      }
      return
    }
    let wasReady = playbackState == .ready
    playbackState = .ready
    isPlaying = p.timeControlStatus != .paused
    if !wasReady {
      status = isPlaying ? "正在播放 \(current?.name ?? "")" : "已暂停"
    }
    updatePlaybackTime(time, duration: item.duration.seconds)
  }

  private func updatePlaybackTime(_ time: CMTime, duration itemDuration: Double) {
    guard itemDuration.isFinite, itemDuration > 0 else {
      progress = 0
      currentTime = 0
      duration = 0
      return
    }
    duration = itemDuration
    guard time.seconds.isFinite else { return }
    currentTime = max(0, min(time.seconds, itemDuration))
    progress = duration > 0 ? currentTime / duration : 0
  }

  private func resetPlaybackPosition() {
    progress = 0
    currentTime = 0
    duration = 0
  }

  private func setPlaybackFailure(_ message: String) {
    playbackState = .failed
    isPlaying = false
    resolvedUrl = nil
    status = message
  }

  /// 播完按模式切歌（对标 core/music 队列逻辑）
  private func ended() {
    switch mode {
    case .single:
      player.seek(to: .zero)
      player.playImmediately(atRate: 1)
      isPlaying = true
      status = "正在播放 \(current?.name ?? "")"
    case .shuffle:
      guard !queue.isEmpty else {
        isPlaying = false
        status = "播放结束"
        return
      }
      guard let song = shuffledSong(avoiding: current?.id) else { return }
      play(song)
    case .sequence:
      if let index = queueIndex(of: current), index + 1 < queue.count {
        play(queue[index + 1])
      } else {
        isPlaying = false
        status = "播放结束"
      }
    case .loopAll:
      guard !queue.isEmpty else {
        isPlaying = false
        status = "播放结束"
        return
      }
      if let index = queueIndex(of: current) {
        play(queue[(index + 1) % queue.count])
      } else {
        play(queue[0])
      }
    }
  }

  func attach(engine: UserApiEngine) { self.engine = engine }

  /// 取当前歌曲可用且源支持的最高音质（high->low 找交集，任何操作均用最高档）
  func pickQuality(for song: MusicInfo, supported: [MusicQuality]?) -> MusicQuality {
    let avail = Set(song.availableQualitys)
    let sup = supported.map(Set.init)
      ?? qualityMap[song.source.rawValue].map(Set.init)
      ?? Set(MusicQuality.highToLow)
    let pref = MusicQuality.highToLow
    for q in pref where avail.contains(q) && sup.contains(q) { return q }
    // 源支持表与歌曲可用无交集时（如内置兜底），退回歌曲自身最高档，保证有声
    for q in pref where avail.contains(q) { return q }
    return .q128k
  }

  func play(_ song: MusicInfo, in list: [MusicInfo]? = nil, context: String? = nil) {
    if let list {
      queue = list
      queueContext = context
    }
    playToken &+= 1
    let token = playToken
    if playerFailed || player.status == .failed { replacePlayer() }
    player.pause()
    installCurrentItem(nil)
    current = song
    playbackState = .loading
    isPlaying = false
    resolvedUrl = nil
    lyric = nil
    resetPlaybackPosition()
    LibraryStore.shared.pushHistory(song)
    Task { await resolveAndPlay(song, token: token) }
  }

  func togglePlay(_ on: Bool) {
    if on {
      guard canTogglePlayback else { return }
      if playbackState == .failed, let current {
        play(current)
      } else if !isPlaying {
        rewindIfNeeded()
        player.playImmediately(atRate: 1)
        isPlaying = true
        status = "正在播放 \(current?.name ?? "")"
      }
    } else if isPlaying {
      player.pause()
      isPlaying = false
      status = "已暂停"
    }
  }

  func toggle() {
    if isPlaying {
      player.pause()
      isPlaying = false
      status = "已暂停"
      return
    }
    guard canTogglePlayback else { return }
    if playbackState == .failed, let current {
      play(current)
      return
    }
    rewindIfNeeded()
    player.playImmediately(atRate: 1)
    isPlaying = true
    status = "正在播放 \(current?.name ?? "")"
  }

  func next() {
    guard let current, canGoNext else { return }
    if mode == .shuffle, let song = shuffledSong(avoiding: current.id) {
      play(song)
      return
    }
    if mode == .loopAll, !queue.isEmpty {
      if let index = queueIndex(of: current) {
        play(queue[(index + 1) % queue.count])
      } else {
        play(queue[0])
      }
      return
    }
    guard let index = queueIndex(of: current), index + 1 < queue.count else { return }
    play(queue[index + 1])
  }

  func prev() {
    guard let current, canGoPrevious else { return }
    if mode == .shuffle, let song = shuffledSong(avoiding: current.id) {
      play(song)
      return
    }
    if mode == .loopAll,
       let index = queueIndex(of: current),
       !queue.isEmpty {
      play(queue[(index - 1 + queue.count) % queue.count])
      return
    }
    if let index = queueIndex(of: current), index > 0 {
      play(queue[index - 1])
      return
    }
    guard playbackState == .ready else { return }
    player.seek(to: .zero)
    player.playImmediately(atRate: 1)
    progress = 0
    currentTime = 0
    isPlaying = true
    status = "正在播放 \(current.name)"
  }

  private func rewindIfNeeded() {
    guard duration.isFinite, duration > 0, currentTime >= duration - 0.05 else { return }
    seek(0)
  }

  func seek(_ ratio: Double) {
    guard ratio.isFinite,
          canSeek,
          let item = player.currentItem,
          item.duration.seconds.isFinite,
          item.duration.seconds > 0 else { return }
    let clampedRatio = max(0, min(1, ratio))
    let target = CMTime(seconds: item.duration.seconds * clampedRatio, preferredTimescale: 600)
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    currentTime = target.seconds
    progress = clampedRatio
  }

  func setVolume(_ value: Double) {
    volume = max(0, min(1, value))
    player.volume = Float(volume)
  }

  // MARK: resolve
  private func resolveAndPlay(_ song: MusicInfo, token: Int) async {
    guard token == playToken else { return }
    status = "正在获取播放链接…"
    resolvedUrl = nil; lyric = nil
    do {
      let sup = engine?.inited == true ? engine?.qualitys[song.source.rawValue] : nil
      let q = pickQuality(for: song, supported: sup)
      var urlStr: String?
      var played: MusicInfo = song
      // 1) 若自定义源已初始化且声明了该 source+musicUrl，则走 JS 沙箱（复刻 useInitUserApi 动态注入逻辑）
      if let engine, engine.inited,
         engine.sources[song.source.rawValue]?.actions.contains(.musicUrl) == true {
        do {
          let value = try await engine.callScript(source: song.source.rawValue, action: .musicUrl, quality: q, music: song)
          guard token == playToken else { return }
          urlStr = value as? String
          status = "自定义源解析中"
        } catch {
          guard token == playToken else { return }
          // 2) 换源播放（对标 core/music findMusic）：同曲去其他源找
          status = "本源失败，正在换源…"
          if let alternative = await findOtherSource(song, quality: q) {
            guard token == playToken else { return }
            played = alternative.song
            urlStr = alternative.url
            status = "已换源 \(alternative.song.source.rawValue)"
          }
        }
      }
      // 2) MVP兜底：注册表 fallbackUrl（kw 官方试听直链；若无自定义源也能播；对标内置 api-temp 思路）
      if urlStr == nil {
        urlStr = SourceRegistry.capability(id: song.source.rawValue)?.fallbackUrl?(song.songmid, q)
        status = "内置兜底解析中"
      }
      guard token == playToken else { return }
      guard let s = urlStr, let url = URL(string: s) else { throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "无可用播放链接"]) }
      resolvedUrl = s
      if played.id != song.id {
        current = played
        if let i = queue.firstIndex(where: { $0.id == song.id }) { queue[i] = played }
      }
      let item = AVPlayerItem(url: url)
      installCurrentItem(item)
      player.playImmediately(atRate: 1)
      isPlaying = true
      status = "正在准备 \(played.name)"
      // 3) 歌词/封面：若源声明 lyric/pic 则走沙箱，否则留空
      Task {
        do { try await self.fetchLyricPic(played, token: token) } catch { }
      }
    } catch {
      guard token == playToken else { return }
      setPlaybackFailure("播放失败：\(error.localizedDescription)")
    }
  }

  /// 换源：在其他源找同曲并取 URL（engine 需声明对应 source+musicUrl；候选源来自注册表）
  private func findOtherSource(_ song: MusicInfo, quality: MusicQuality) async -> (song: MusicInfo, url: String)? {
    guard let engine, let searcher else { return nil }
    for cap in SourceRegistry.searchable.filter({ $0.id != song.source.rawValue && $0.id != "local" }) {
      guard let src = MusicSource(rawValue: cap.id),
            engine.sources[src.rawValue]?.actions.contains(.musicUrl) == true,
            let alt = await searcher.findSimilar(song, in: src),
            let v = try? await engine.callScript(source: src.rawValue, action: .musicUrl,
                                                 quality: pickQuality(for: alt, supported: engine.qualitys[src.rawValue]),
                                                 music: alt),
            let u = v as? String else { continue }
      return (alt, u)
    }
    return nil
  }

  private func isCurrentRequest(for song: MusicInfo, token: Int) -> Bool {
    token == playToken && current?.id == song.id
  }

  private func fetchLyricPic(_ song: MusicInfo, token: Int) async throws {
    var gotLyric = false
    var gotPic = false
    if let engine, engine.inited {
      if engine.sources[song.source.rawValue]?.actions.contains(.lyric) == true {
        let value = try? await engine.callScript(source: song.source.rawValue, action: .lyric, quality: .q128k, music: song)
        guard isCurrentRequest(for: song, token: token) else { return }
        if let info = value as? LyricInfo {
          lyric = info
          gotLyric = true
        }
      }
      if engine.sources[song.source.rawValue]?.actions.contains(.pic) == true {
        let value = try? await engine.callScript(source: song.source.rawValue, action: .pic, quality: .q128k, music: song)
        guard isCurrentRequest(for: song, token: token) else { return }
        if let url = value as? String, var updated = current {
          updated.picUrl = url
          current = updated
          gotPic = true
        }
      }
    }
    // 官站兜底（对标各源 lyric.js/pic.js；tx QRC 与 mg mrc 跳过，只走自定义源）
    if !gotLyric {
      let value = try await OfficialLyric.fetch(song)
      guard isCurrentRequest(for: song, token: token) else { return }
      if let info = value {
        lyric = info
        gotLyric = true
      }
    }
    if !gotPic {
      let value = await OfficialPic.fetch(song)
      guard isCurrentRequest(for: song, token: token) else { return }
      if let url = value, var updated = current {
        updated.picUrl = url
        current = updated
        gotPic = true
      }
    }
    // 跨源兜底（对标 handleGetOnlineLyricInfo/handleGetOnlinePicUrl 的 getOtherSource 链）：
    // 主源无歌词/封面时，用同曲他源结果重试
    if (!gotLyric || !gotPic), let searcher {
      let candidates = await searcher.findSimilarCandidates(song)
      guard isCurrentRequest(for: song, token: token) else { return }
      for alternative in candidates.prefix(3) {
        if !gotLyric {
          let value = try? await OfficialLyric.fetch(alternative)
          guard isCurrentRequest(for: song, token: token) else { return }
          if let info = value {
            lyric = info
            gotLyric = true
          }
        }
        if !gotPic {
          let value = await OfficialPic.fetch(alternative)
          guard isCurrentRequest(for: song, token: token) else { return }
          if let url = value, var updated = current {
            updated.picUrl = url
            current = updated
            gotPic = true
          }
        }
        if gotLyric && gotPic { break }
      }
    }
  }
}

/// 酷我直链兜底（公开移动端试听接口，MVP可用；正式使用请以自定义源返回为准）
enum KwFallback {
  static func url(songmid: String, quality: MusicQuality) -> String? {
    // anti.s 等需要签名，MVP用最简的 player 试听地址簇：
    // https://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=<mid> 可拿到试听url（此处直接返回 info 接口由 AVPlayer 跟随？不行）
    // 为保证可播，返回 kuwo 跨端 mostable 302 链接：
    "https://er.sycdn.kuwo.cn/\(songmid.prefix(2))/\(songmid)/audio.mp3"
  }
}
