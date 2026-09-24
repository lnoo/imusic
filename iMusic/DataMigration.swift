import Foundation

// MARK: - DataMigration（一次性）：老名字 -> iMusic 改名搬家
// bundle id 换过两代（com.lxmusic.mac、com.music.mac），数据目录换过两代
// （LxMusicMac、MusicMac），为不丢老数据（自定义源 user_api.json / 歌单
// library.json / 榜单缓存 / 下载歌曲 / 偏好），首次启动把老位置整体搬到新位置。
// 幂等：新位置已有内容则只补缺失文件，不覆盖。
// 注意：磁盘目录用 iMusic，避免与系统 Apple Music
// （~/Music/Music、Application Support/Music）撞车；界面产品名同样叫 iMusic。

enum DataMigration {
  private static let oldAppSupports = ["MusicMac", "LxMusicMac"] // 新优先
  private static let newAppSupport = "iMusic"
  private static let oldDefaultsDomains = ["com.music.mac", "com.lxmusic.mac"] // 新优先
  /// 从老默认域搬过来的偏好键（窗口位置等系统键不搬）
  private static let prefKeys = ["common.apiSource", "proxy.host", "proxy.port", "openApi.port"]

  static func run() {
    let fm = FileManager.default
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    for old in oldAppSupports {
      migrateDir(
        from: appSupport.appendingPathComponent(old, isDirectory: true),
        to: appSupport.appendingPathComponent(newAppSupport, isDirectory: true))
    }
    if let music = fm.urls(for: .musicDirectory, in: .userDomainMask).first {
      for old in oldAppSupports {
        migrateDir(
          from: music.appendingPathComponent(old, isDirectory: true),
          to: music.appendingPathComponent(newAppSupport, isDirectory: true))
      }
    }
    migrateDefaults()
  }

  private static func migrateDir(from old: URL, to new: URL) {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return }
    if !fm.fileExists(atPath: new.path) {
      try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
      if (try? fm.moveItem(at: old, to: new)) != nil { return }
    }
    // 新位置已存在（或移动失败）兜底：逐文件补缺失（不覆盖），老目录保留不删
    try? fm.createDirectory(at: new, withIntermediateDirectories: true)
    for item in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
      let dest = new.appendingPathComponent(item.lastPathComponent)
      if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: item, to: dest) }
    }
  }

  private static func migrateDefaults() {
    let cur = UserDefaults.standard
    for domain in oldDefaultsDomains {
      guard let old = UserDefaults(suiteName: domain) else { continue }
      for k in prefKeys {
        guard cur.object(forKey: k) == nil, let v = old.object(forKey: k) else { continue }
        cur.set(v, forKey: k)
      }
    }
  }
}
