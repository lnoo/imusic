import Foundation
import SwiftUI
import Observation

// MARK: - UserApiStore
// 对标：
//  - src/main/utils/store.ts (user_api.json / config_v2.json持久化)
//  - src/main/modules/userApi/utils.ts (getUserApis/importApi/removeApi/getScript)
//  - src/renderer/store/setting.ts setApiSource + common.apiSource
//  - src/renderer/views/Setting/components/UserApiModal.vue + UserApiOnlineImportModal.vue
//
// 存储：~/Library/Application Support/iMusic/user_api.json + UserDefaults(common.apiSource)
// script 字段格式：gz_+base64(zlib)，与桌面端完全互通（可直接复制 user_api.json）

@Observable @MainActor
final class UserApiStore {
  static let shared = UserApiStore()

  var list: [UserApiInfo] = []
  /// 当前生效源ID，对标 appSetting['common.apiSource']，默认 "temp"
  var activeSourceId: String = UserDefaults.standard.string(forKey: "common.apiSource") ?? "temp"
  var statusMessage: String = "未初始化"
  var updateAlert: UpdateAlert?

  private var fulls: [String: UserApiInfoFull] = [:] // id -> full（含压缩script）
  private let fm = FileManager.default

  private var supportDir: URL {
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("iMusic", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
  private var storeFile: URL { supportDir.appendingPathComponent("user_api.json") }

  init() {
    load()
  }

  // MARK: load / save
  struct FileRoot: Codable { var userApis: [UserApiInfoFull] }

  func load() {
    guard let data = try? Data(contentsOf: storeFile),
          let root = try? JSONDecoder().decode(FileRoot.self, from: data) else {
      list = []; fulls = [:]; return
    }
    fulls = Dictionary(uniqueKeysWithValues: root.userApis.map { ($0.id, $0) })
    list = root.userApis.map {
      UserApiInfo(id: $0.id, name: $0.name, description: $0.description,
                  author: $0.author, homepage: $0.homepage, version: $0.version,
                  allowShowUpdateAlert: $0.allowShowUpdateAlert, sources: nil)
    }
    // 若active指向已删除的源，回退
    if activeSourceId.hasPrefix("user_api_") && !fulls.keys.contains(activeSourceId) {
      activeSourceId = "temp"
    }
  }

  private func save() {
    let arr = list.compactMap { info -> UserApiInfoFull? in
      guard let f = fulls[info.id] else { return nil }
      return UserApiInfoFull(id: info.id, name: info.name, description: info.description,
                             author: info.author, homepage: info.homepage, version: info.version,
                             allowShowUpdateAlert: info.allowShowUpdateAlert, script: f.script)
    }
    if let data = try? JSONEncoder().encode(FileRoot(userApis: arr)) {
      try? data.write(to: storeFile)
    }
    UserDefaults.standard.set(activeSourceId, forKey: "common.apiSource")
  }

  // MARK: - 导入（复刻 UserApiOnlineImportModal + UserApiModal + utils.importApi）
  // 在线URL: 校验 ^https?:// ，>9MB 拒绝
  // 本地文件: .js 文本
  // 去重：压缩后 script 字符串完全相等则拒绝（与原项目一致）

  func importFromURL(_ urlString: String) async throws -> UserApiInfo {
    guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://"),
          let url = URL(string: urlString) else {
      throw URLError(.badURL)
    }
    let (data, _) = try await URLSession.shared.data(from: url)
    guard data.count <= 9_000_000 else { throw SourceScriptError.tooLarge }
    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .gbkFallback) else {
      throw SourceScriptError.invalidFile
    }
    return try importRawScript(text)
  }

  func importFromFile(_ url: URL) throws -> UserApiInfo {
    // 兼容 fileImporter 的 security scope
    _ = url.startAccessingSecurityScopedResource()
    defer { url.stopAccessingSecurityScopedResource() }
    let text = try String(contentsOf: url, encoding: .utf8)
    return try importRawScript(text)
  }

  @discardableResult
  func importRawScript(_ raw: String) throws -> UserApiInfo {
    guard raw.utf8.count <= 9_000_000 else { throw SourceScriptError.tooLarge }
    if list.count >= 20 { throw SourceScriptError.tooLarge } // 原项目 list.length>20 拒绝
    let meta = try SourceScriptParser.parseMeta(raw)
    let stored = try SourceScriptParser.deflateToStorage(raw)
    for (_, f) in fulls where f.script == stored {
      throw SourceScriptError.duplicated(existingName: f.name)
    }
    // id 规则：user_api_<rand3>_<timestamp>（复刻 utils.ts:121）
    let id = "user_api_\(String(Int.random(in: 100...999)))_\(Int(Date().timeIntervalSince1970 * 1000))"
    let full = UserApiInfoFull(id: id, name: meta.name, description: meta.description,
                               author: meta.author, homepage: meta.homepage, version: meta.version,
                               allowShowUpdateAlert: true, script: stored)
    fulls[id] = full
    list.append(UserApiInfo(id: id, name: meta.name, description: meta.description,
                            author: meta.author, homepage: meta.homepage, version: meta.version,
                            allowShowUpdateAlert: true, sources: nil))
    save()
    return list.last!
  }

  func rawScript(id: String) throws -> String {
    guard let f = fulls[id] else { throw SourceScriptError.invalidFile }
    return try SourceScriptParser.inflateFromStorage(f.script)
  }

  // MARK: - 删除 / 选择（复刻 UserApiModal.vue:99-107 removeApi）
  func remove(ids: Set<String>) {
    list.removeAll { ids.contains($0.id) }
    for id in ids { fulls.removeValue(forKey: id) }
    if ids.contains(activeSourceId) {
      activeSourceId = list.first?.id ?? "temp" // 原项目回退到 backApi
    }
    save()
    // 切换后由调用方重新 setActive -> 触发沙箱重载
  }

  /// 选择生效源，对标 setApiSource + setUserApi(apiId)
  /// 返回 true 表示需要重载 JS 沙箱（user_api_*），false 表示内置 temp（MVP 搜索仍可用）
  func setActive(_ id: String) {
    activeSourceId = id
    save()
  }

  func updateInitedSources(id: String, sources: [String: UserApiSourceInfo]) {
    if let i = list.firstIndex(where: { $0.id == id }) {
      list[i].sources = sources
    }
  }
}

// GBK fallback helper（部分源文件可能是GBK，MVP仅尽力）
private extension String.Encoding {
  static var gbkFallback: String.Encoding {
    // CoreFoundation GBK = 0x0632
    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
  }
}
