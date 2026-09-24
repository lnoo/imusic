import Foundation
import SwiftUI
import Observation

// MARK: - 下载器（对标 core/music/download.ts + common/utils/download/Downloader.ts）
// URLSession 下载队列 + 进度；落盘 ~/Music/iMusic/歌手 - 歌名.mp3 + 同名 .lrc/.jpg。
// 说明：桌面端 musicMeta 的内嵌标签（mp3/flac 写封面+歌词）MVP 用 sidecar 文件代替，未做二进制标签写入。

struct DownloadTask: Identifiable, Sendable {
  var id: String
  var song: MusicInfo
  var progress: Double = 0
  var state: String = "等待中"
}

@Observable @MainActor
final class DownloadStore {
  static let shared = DownloadStore()
  var tasks: [DownloadTask] = []

  private var running: [String: URLSessionDownloadTask] = [:]
  private let session = URLSession(configuration: .default)

  private var dir: URL {
    let d = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
      .appendingPathComponent("iMusic", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }

  private func safe(_ s: String) -> String {
    s.replacingOccurrences(of: "/", with: "、").replacingOccurrences(of: ":", with: "：")
  }
  private func baseName(_ song: MusicInfo) -> String { "\(safe(song.singer)) - \(safe(song.name))" }

  func enqueue(_ song: MusicInfo, urlString: String) {
    guard let url = URL(string: urlString),
          !tasks.contains(where: { $0.id == song.id }) else { return }
    tasks.append(DownloadTask(id: song.id, song: song))
    start(song, url: url)
  }

  func cancel(_ id: String) {
    running[id]?.cancel(); running.removeValue(forKey: id)
    if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].state = "已取消" }
  }

  private func setState(_ id: String, _ s: String, _ p: Double? = nil) {
    guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
    tasks[i].state = s
    if let p { tasks[i].progress = p }
  }

  private func start(_ song: MusicInfo, url: URL) {
    setState(song.id, "下载中")
    let task = session.downloadTask(with: url) { [weak self] tmp, _, err in
      Task { @MainActor in
        guard let self else { return }
        self.running.removeValue(forKey: song.id)
        if let err {
          self.setState(song.id, "失败：\(err.localizedDescription.prefix(30))"); return
        }
        guard let tmp else { self.setState(song.id, "失败：无数据"); return }
        do {
          let dest = self.dir.appendingPathComponent(self.baseName(song) + ".mp3")
          if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
          try FileManager.default.moveItem(at: tmp, to: dest)
          // 歌词/封面 sidecar（对标下载时顺带存歌词封面的逻辑）
          if let lrc = try await OfficialLyric.fetch(song) {
            try? lrc.lyric.write(to: self.dir.appendingPathComponent(self.baseName(song) + ".lrc"), atomically: true, encoding: .utf8)
          }
          if let pic = await OfficialPic.fetch(song), let u = URL(string: pic),
             let (data, _) = try? await URLSession.shared.data(from: u) {
            try? data.write(to: self.dir.appendingPathComponent(self.baseName(song) + ".jpg"))
          }
          self.setState(song.id, "已完成", 1)
        } catch {
          self.setState(song.id, "失败：\(error.localizedDescription.prefix(30))")
        }
      }
    }
    running[song.id] = task
    task.resume()
    // 粗进度轮询（URLSessionDownloadTask 代理太重，MVP 用 KVO 替代：此处用定时采样）
    Task { await self.poll(task, id: song.id) }
  }

  private func poll(_ task: URLSessionDownloadTask, id: String) async {
    while running[id] != nil {
      try? await Task.sleep(nanoseconds: 400_000_000)
      let p = task.progress.fractionCompleted
      if p > 0 { setState(id, "下载中 \(Int(p * 100))%", p) }
    }
  }
}
