import Foundation
import SwiftUI
import Observation

// MARK: - 资料库（对标 renderer/store/list + dislikeList）
// 歌单 CRUD + 不喜欢名单 + 播放历史，JSON 落盘 Application Support/iMusic/

struct Playlist: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var songs: [MusicInfo]
}

@Observable @MainActor
final class LibraryStore {
  static let shared = LibraryStore()
  var playlists: [Playlist] = []
  var disliked: Set<String> = [] // MusicInfo.id 集合（对标 dislikeList）
  var history: [MusicInfo] = [] // 最近播放（最多100）

  private let fm = FileManager.default
  private var dir: URL {
    let d = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("iMusic", isDirectory: true)
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }

  init() { load() }

  private struct Root: Codable { var playlists: [Playlist]; var disliked: [String]; var history: [MusicInfo] }
  private var file: URL { dir.appendingPathComponent("library.json") }

  func load() {
    guard let data = try? Data(contentsOf: file),
          let r = try? JSONDecoder().decode(Root.self, from: data) else {
      playlists = [Playlist(id: "fav", name: "我喜欢", songs: [])]
      return
    }
    playlists = r.playlists.isEmpty ? [Playlist(id: "fav", name: "我喜欢", songs: [])] : r.playlists
    disliked = Set(r.disliked)
    history = r.history
  }

  private func save() {
    let r = Root(playlists: playlists, disliked: Array(disliked), history: Array(history.prefix(100)))
    if let d = try? JSONEncoder().encode(r) { try? d.write(to: file) }
  }

  // MARK: 歌单
  func createPlaylist(_ name: String) {
    playlists.append(Playlist(id: "pl_\(Int(Date().timeIntervalSince1970 * 1000))", name: name, songs: []))
    save()
  }
  func renamePlaylist(_ id: String, _ name: String) {
    guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
    playlists[i].name = name; save()
  }
  func deletePlaylist(_ id: String) {
    guard id != "fav" else { return }
    playlists.removeAll { $0.id == id }; save()
  }
  /// 按 id 去重加入（对标 list 去重逻辑）
  func add(_ song: MusicInfo, to playlistId: String) {
    guard let i = playlists.firstIndex(where: { $0.id == playlistId }),
          !playlists[i].songs.contains(where: { $0.id == song.id }) else { return }
    playlists[i].songs.append(song); save()
  }
  func remove(_ song: MusicInfo, from playlistId: String) {
    guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
    playlists[i].songs.removeAll { $0.id == song.id }; save()
  }

  // MARK: dislike / history
  func toggleDislike(_ song: MusicInfo) {
    if disliked.contains(song.id) { disliked.remove(song.id) } else { disliked.insert(song.id) }
    save()
  }
  func pushHistory(_ song: MusicInfo) {
    history.removeAll { $0.id == song.id }
    history.insert(song, at: 0)
    history = Array(history.prefix(100))
    save()
  }
}
