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
// 存储：~/Library/Application Support/iMusic/user_api.json
// script 字段格式：gz_+base64(zlib)，与桌面端完全互通（可直接复制 user_api.json）
//
// 音源清单（JSON）对标 shellsec/lx-music-source 的 sources.json：
// 清单只提供 {id, name, url}，按 url 下载 JS 后复用 importRawScript 管线。

@Observable @MainActor
final class UserApiStore {
  static let shared = UserApiStore()

  var list: [UserApiInfo] = []
  /// 有序启用的源 ID（对标 config.ts `enabledScripts`，max 3，数组顺序 = 优先级）
  var enabledSourceIds: [String] = []
  /// 当前首选源：首个启用 id（没有启用源时为 "temp"）
  var activeSourceId: String {
    get { enabledSourceIds.first ?? "temp" }
    set { setActive(newValue) }
  }
  var statusMessage: String = "未初始化"
  var updateAlert: UpdateAlert?

  private var fulls: [String: UserApiInfoFull] = [:] // id -> full（含压缩script）
  private let fm = FileManager.default

  /// JS 脚本上限（与原项目一致）
  private static let scriptMaxBytes = 9_000_000
  /// 清单文件上限（清单只含索引，1MB 足够）
  private static let manifestMaxBytes = 1_000_000
  /// 与原项目一致的导入数量上限
  private static let maxSources = 20
  /// config.ts enabledScripts.max = 3
  static let maxEnabledSources = 3

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
  struct FileRoot: Codable {
    var userApis: [UserApiInfoFull]
    var enabledSourceIds: [String]
  }

  func load() {
    guard let data = try? Data(contentsOf: storeFile),
          let root = try? JSONDecoder().decode(FileRoot.self, from: data) else {
      list = []; fulls = [:]; enabledSourceIds = []; return
    }
    fulls = Dictionary(uniqueKeysWithValues: root.userApis.map { ($0.id, $0) })
    list = root.userApis.map {
      UserApiInfo(id: $0.id, name: $0.name, description: $0.description,
                  author: $0.author, homepage: $0.homepage, version: $0.version,
                  allowShowUpdateAlert: $0.allowShowUpdateAlert, sources: nil,
                  manifestURL: $0.manifestURL, sourceId: $0.sourceId)
    }
    // 去重 + 过滤已删除 id + 上限 3
    var seen = Set<String>()
    let enabled = root.enabledSourceIds.filter {
      fulls.keys.contains($0) && seen.insert($0).inserted
    }
    enabledSourceIds = Array(enabled.prefix(Self.maxEnabledSources))
  }

  private func save() {
    let arr = list.compactMap { info -> UserApiInfoFull? in
      guard let f = fulls[info.id] else { return nil }
      return UserApiInfoFull(id: info.id, name: info.name, description: info.description,
                             author: info.author, homepage: info.homepage, version: info.version,
                             allowShowUpdateAlert: info.allowShowUpdateAlert, script: f.script,
                             manifestURL: info.manifestURL, sourceId: info.sourceId)
    }
    if let data = try? JSONEncoder().encode(FileRoot(userApis: arr, enabledSourceIds: enabledSourceIds)) {
      try? data.write(to: storeFile)
    }
  }

  // MARK: - JSON 音源清单
  // 在线 URL / 本地文件统一解析为 ManifestSource 列表，由 UI 决定导入哪些条目。
  // 条目 url 仅接受 http(s)，下载后的 JS 内容走与直接导入完全相同的校验管线。

  /// 读取在线清单（不落盘，仅返回列表）
  func fetchManifest(from urlString: String) async throws -> [ManifestSource] {
    let url = try validatedHTTPURL(urlString)
    let (data, response) = try await URLSession.shared.data(from: url)
    try checkHTTP(response)
    guard data.count <= Self.manifestMaxBytes else { throw SourceImportError.manifestTooLarge }
    return try parseManifest(data)
  }

  /// 读取本地清单文件（兼容 fileImporter 的 security scope）
  func loadManifest(from fileURL: URL) throws -> [ManifestSource] {
    _ = fileURL.startAccessingSecurityScopedResource()
    defer { fileURL.stopAccessingSecurityScopedResource() }
    let data = try Data(contentsOf: fileURL)
    guard data.count <= Self.manifestMaxBytes else { throw SourceImportError.manifestTooLarge }
    return try parseManifest(data)
  }

  private func parseManifest(_ data: Data) throws -> [ManifestSource] {
    let root: SourceManifest
    do {
      root = try JSONDecoder().decode(SourceManifest.self, from: data)
    } catch {
      throw SourceImportError.invalidManifest
    }
    guard !root.sources.isEmpty else { throw SourceImportError.emptyManifest }

    var seen = Set<String>()
    var result: [ManifestSource] = []
    for raw in root.sources {
      let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let url = raw.url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty, !name.isEmpty, isValidHTTPURL(url) else {
        throw SourceImportError.invalidManifestEntry(name.isEmpty ? raw.name : name)
      }
      // 清单内 id 重复时只保留第一条
      if seen.insert(id).inserted {
        result.append(ManifestSource(id: id, name: name, url: url))
      }
    }
    guard !result.isEmpty else { throw SourceImportError.emptyManifest }
    return result
  }

  /// 按清单条目下载 JS 并导入；manifestURL 为清单来源标识（在线地址或 local://文件名）
  func importFromManifest(_ entry: ManifestSource, manifestURL: String) async throws -> UserApiInfo {
    let url = try validatedHTTPURL(entry.url)
    let (data, response) = try await URLSession.shared.data(from: url)
    try checkHTTP(response)
    guard data.count <= Self.scriptMaxBytes else { throw SourceScriptError.tooLarge }
    guard let text = decodeScriptText(data) else { throw SourceScriptError.invalidFile }
    return try importRawScript(text, manifestURL: manifestURL, sourceId: entry.id)
  }

  // MARK: - 导入（复刻 UserApiOnlineImportModal + UserApiModal + utils.importApi）
  // 在线URL: 校验 ^https?:// ，>9MB 拒绝
  // 本地文件: .js 文本
  // 去重：压缩后 script 字符串完全相等则拒绝（与原项目一致）
  // 清单导入：同一 manifestURL + sourceId 也视为重复

  func importFromURL(_ urlString: String) async throws -> UserApiInfo {
    let url = try validatedHTTPURL(urlString)
    let (data, response) = try await URLSession.shared.data(from: url)
    try checkHTTP(response)
    guard data.count <= Self.scriptMaxBytes else { throw SourceScriptError.tooLarge }
    guard let text = decodeScriptText(data) else { throw SourceScriptError.invalidFile }
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
  func importRawScript(_ raw: String, manifestURL: String? = nil, sourceId: String? = nil) throws -> UserApiInfo {
    guard raw.utf8.count <= Self.scriptMaxBytes else { throw SourceScriptError.tooLarge }
    if list.count >= Self.maxSources { throw SourceScriptError.tooLarge } // 原项目 list.length>20 拒绝
    // 清单条目去重：同一清单的同一 id 不重复导入（脚本内容去重在下方仍保留）
    if let manifestURL, let sourceId,
       let existing = list.first(where: { $0.manifestURL == manifestURL && $0.sourceId == sourceId }) {
      throw SourceImportError.manifestSourceExists(existing.name)
    }
    let meta = try SourceScriptParser.parseMeta(raw)
    let stored = try SourceScriptParser.deflateToStorage(raw)
    for (_, f) in fulls where f.script == stored {
      throw SourceScriptError.duplicated(existingName: f.name)
    }
    // id 规则：user_api_<rand3>_<timestamp>（复刻 utils.ts:121）
    let id = "user_api_\(String(Int.random(in: 100...999)))_\(Int(Date().timeIntervalSince1970 * 1000))"
    let full = UserApiInfoFull(id: id, name: meta.name, description: meta.description,
                               author: meta.author, homepage: meta.homepage, version: meta.version,
                               allowShowUpdateAlert: true, script: stored,
                               manifestURL: manifestURL, sourceId: sourceId)
    fulls[id] = full
    let info = UserApiInfo(id: id, name: meta.name, description: meta.description,
                           author: meta.author, homepage: meta.homepage, version: meta.version,
                           allowShowUpdateAlert: true, sources: nil,
                           manifestURL: manifestURL, sourceId: sourceId)
    list.append(info)
    save()
    return list.last!
  }

  func rawScript(id: String) throws -> String {
    guard let f = fulls[id] else { throw SourceScriptError.invalidFile }
    return try SourceScriptParser.inflateFromStorage(f.script)
  }

  // MARK: - 删除 / 启用（复刻 UserApiModal.vue:99-107 removeApi + config enabledScripts）
  func remove(ids: Set<String>) {
    list.removeAll { ids.contains($0.id) }
    for id in ids { fulls.removeValue(forKey: id) }
    // 移除已删除的启用项（activeSourceId 是 computed alias，自动随之回退）
    enabledSourceIds.removeAll { ids.contains($0) }
    save()
    // 切换后由调用方重新 reloadSource -> 触发沙箱重载
  }

  /// 设置有序启用源：仅接受 list 中存在的 id，去重并截断到 3 个。
  func setEnabled(_ ids: [String]) {
    var seen = Set<String>()
    enabledSourceIds = ids.filter { id in
      list.contains { $0.id == id } && seen.insert(id).inserted
    }
    .prefix(Self.maxEnabledSources)
    .map { $0 }
    save()
  }

  func isEnabled(id: String) -> Bool { enabledSourceIds.contains(id) }

  /// 设置首选源：置顶到启用列表首位，其余保留，最多 3 个。
  /// "temp" 表示清空启用列表，回到内置模式。
  func setActive(_ id: String) {
    if id == "temp" {
      enabledSourceIds = []
    } else if list.contains(where: { $0.id == id }) {
      var ids = enabledSourceIds.filter { $0 != id }
      ids.insert(id, at: 0)
      enabledSourceIds = Array(ids.prefix(Self.maxEnabledSources))
    }
    save()
  }

  /// 导出所有已导入脚本（对标 command.ts exportSources：按导入顺序写出 <name>.js）
  /// 返回解压后的脚本文本；个别损坏项跳过。
  func exportSources() -> [(name: String, script: String)] {
    list.compactMap { info in
      guard let full = fulls[info.id], let raw = try? SourceScriptParser.inflateFromStorage(full.script) else { return nil }
      return (name: info.name, script: raw)
    }
  }

  func updateInitedSources(id: String, sources: [String: UserApiSourceInfo]) {
    if let i = list.firstIndex(where: { $0.id == id }) {
      list[i].sources = sources
    }
  }

  // MARK: - 网络 / 解码小工具

  private func isValidHTTPURL(_ s: String) -> Bool {
    (s.hasPrefix("http://") || s.hasPrefix("https://")) && URL(string: s) != nil
  }

  private func validatedHTTPURL(_ s: String) throws -> URL {
    guard isValidHTTPURL(s), let url = URL(string: s) else {
      throw SourceImportError.invalidURL
    }
    return url
  }

  private func checkHTTP(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      throw SourceImportError.httpError(http.statusCode)
    }
  }

  private func decodeScriptText(_ data: Data) -> String? {
    String(data: data, encoding: .utf8) ?? String(data: data, encoding: .gbkFallback)
  }
}

// MARK: - 清单/导入错误

enum SourceImportError: LocalizedError {
  case invalidURL
  case httpError(Int)
  case manifestTooLarge
  case invalidManifest
  case emptyManifest
  case invalidManifestEntry(String)
  case manifestSourceExists(String)

  var errorDescription: String? {
    switch self {
    case .invalidURL: return "请输入有效的 http(s) 地址"
    case .httpError(let code): return "下载失败（HTTP \(code)）"
    case .manifestTooLarge: return "清单过大（>1MB，拒绝导入）"
    case .invalidManifest: return "JSON 格式无效：需要 { \"sources\": [ { \"id\", \"name\", \"url\" } ] }"
    case .emptyManifest: return "清单中没有可用音源"
    case .invalidManifestEntry(let n): return "清单条目「\(n)」缺少有效的 name 或 http(s) url"
    case .manifestSourceExists(let n): return "清单条目「\(n)」已导入过"
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
