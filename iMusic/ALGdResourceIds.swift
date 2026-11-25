import Foundation

// MARK: - GD音乐台资源 ID 缓存 + gd:v1: 身份层
//
// 移植自 extensions/gdstudio（只读参考）：
//   src/shared/resourceIdCache.ts   picId/lyricId 缓存（内存镜像 + 文件持久化）
//   src/identity.ts                 gd:v1:<source>:<rawId> 身份构造与 gd 源名校验
//   src/index.ts:216-386            ensureResourceIds / buildMusicInfo 的资源 ID 部分
//
// 只保留当前 v1 身份与缓存格式：不读取、不迁移任何旧版缓存/配置。
// Foundation only，可被 CLI 探针单独编译验证。

/// ensure 所需资源类型（对标 index.ts 的 `type ResourceIdType = 'pic' | 'lyric'`）
enum ResourceIdType: String, Sendable {
  case pic
  case lyric
}

/// 线程安全的可变状态容器（NSLock 保护全部字段）；@unchecked 仅在锁的约定下成立。
private final class ALGdResourceIdsBox: @unchecked Sendable {
  let lock = NSLock()
  var entries: [String: ALGdResourceIds.ResourceIds] = [:]
  var loaded = false
  var inFlight: [String: Task<ALGdResourceIds.ResourceIds?, Never>] = [:]
}

enum ALGdResourceIds {
  /// GD 条目上的两个资源 ID（对标 resourceIdCache.ts 的 ResourceIds）
  struct ResourceIds: Codable, Sendable {
    var picId: String?
    var lyricId: String?
  }

  /// identity.ts 的 10 个合法 gd 源名（已去除 gd-/gd_ 前缀的规范名）
  private static let gdSources: Set<String> = [
    "netease", "kuwo", "joox", "tencent", "tidal",
    "qobuz", "bilibili", "apple", "ytmusic", "spotify",
  ]

  private static let box = ALGdResourceIdsBox()

  // MARK: - 文件路径

  /// ~/Library/Application Support/iMusic/gd_resource_ids.json
  private static var cacheFileURL: URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base
      .appendingPathComponent("iMusic", isDirectory: true)
      .appendingPathComponent("gd_resource_ids.json")
  }

  /// 缓存键：规范化源 + 原始 id（对标 `JSON.stringify([source, musicId])` / buildResourceCacheKey）
  private static func cacheKey(source: String, musicId: String) -> String {
    "\(toGdSource(source) ?? source)|\(musicId)"
  }

  // MARK: - 磁盘 IO（只在锁内调用）

  private static func loadLocked() {
    guard !box.loaded else { return }
    box.loaded = true
    guard let data = try? Data(contentsOf: cacheFileURL),
          let decoded = try? JSONDecoder().decode([String: ResourceIds].self, from: data)
    else { return }
    box.entries = decoded
  }

  private static func persistLocked() {
    guard let data = try? JSONEncoder().encode(box.entries) else { return }
    let url = cacheFileURL
    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent("gd_resource_ids.\(UUID().uuidString).tmp")
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try data.write(to: tmp, options: .atomic)
      if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
      } else {
        try FileManager.default.moveItem(at: tmp, to: url)
      }
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      // 写盘失败不影响内存镜像
    }
  }

  // MARK: - 资源 ID 读写

  /// 读取缓存条目；首次调用时从磁盘加载。找不到返回 nil。
  static func get(source: String, musicId: String) -> ResourceIds? {
    let key = cacheKey(source: source, musicId: musicId)
    return box.lock.withLock {
      loadLocked()
      return box.entries[key]
    }
  }

  /// 写入内存镜像并原子落盘。
  static func set(source: String, musicId: String, ids: ResourceIds) {
    let key = cacheKey(source: source, musicId: musicId)
    box.lock.withLock {
      loadLocked()
      box.entries[key] = ids
      persistLocked()
    }
  }

  /// 字符串/数字 → 非空资源 id（对标 index.ts getOptionalResourceId）
  private static func optionalId(_ value: Any?) -> String? {
    guard let v = value else { return nil }
    let raw: String
    if let s = v as? String { raw = s }
    else if let n = v as? NSNumber { raw = n.stringValue }
    else if let i = v as? Int { raw = String(i) }
    else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// types=search 找到精确 id 后提取 pic_id / lyric_id 并缓存（并发请求去重）
  private static func fetchAndCache(gdSource: String, musicId: String,
                                    name: String, artist: String?) async -> ResourceIds? {
    if let cached = get(source: gdSource, musicId: musicId) { return cached }
    guard !name.isEmpty else { return nil }

    let queryName = artist.map { $0.isEmpty ? name : "\(name) \($0)" } ?? name
    let encoded = queryName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? queryName
    let url = "\(AnyListenGD.api)?types=search&count=50&source=\(gdSource)&pages=1&name=\(encoded)"
    guard let json = try? await ALHttp.getJSON(url, headers: AnyListenGD.headers()) else { return nil }
    let items = ALHttp.arr(json) ?? ALHttp.arr(ALHttp.dict(json)?["data"]) ?? []
    guard let exact = items.first(where: {
      optionalId($0["id"]) == musicId
    }) else { return nil }

    let ids = ResourceIds(picId: optionalId(exact["pic_id"]), lyricId: optionalId(exact["lyric_id"]))
    set(source: gdSource, musicId: musicId, ids: ids)
    return ids
  }

  /// 对标 index.ts ensureResourceIds（290-353）：
  /// 1) musicInfo 已自带所需类型的 id → 直接返回；
  /// 2) 命中文件缓存 → 返回缓存（与自带 id 合并，自带优先）；
  /// 3) 否则 types=search 精确匹配原始 id，提取 pic_id/lyric_id，缓存后返回。
  /// 失败返回 nil（iMusic 是值类型 MusicInfo，不回写 meta）。
  static func ensure(source: String, musicInfo: MusicInfo, requiredType: ResourceIdType) async -> ResourceIds? {
    let extra = musicInfo.extra ?? [:]
    let hadPicId = extra.keys.contains("_picId")
    let hadLyricId = extra.keys.contains("_lyricId")
    let current = ResourceIds(
      picId: optionalId(extra["_picId"]),
      lyricId: optionalId(extra["_lyricId"])
    )
    if (requiredType == .pic && hadPicId) || (requiredType == .lyric && hadLyricId) {
      return current
    }

    guard let gdSource = toGdSource(source) else { return nil }
    let musicId = {
      if let raw = extra["musicId"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return raw
      }
      return musicInfo.songmid
    }()
    guard !musicId.isEmpty else { return nil }

    let name = musicInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    let singer = musicInfo.singer.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = cacheKey(source: gdSource, musicId: musicId)

    let task: Task<ResourceIds?, Never> = box.lock.withLock { () -> Task<ResourceIds?, Never> in
      if let running = box.inFlight[key] { return running }
      let running = Task<ResourceIds?, Never> {
        defer { _ = box.lock.withLock { box.inFlight.removeValue(forKey: key) } }
        return await fetchAndCache(
          gdSource: gdSource,
          musicId: musicId,
          name: name,
          artist: singer.isEmpty ? nil : singer
        )
      }
      box.inFlight[key] = running
      return running
    }
    guard let resolved = await task.value else { return nil }

    return ResourceIds(
      picId: hadPicId ? current.picId : resolved.picId,
      lyricId: hadLyricId ? current.lyricId : resolved.lyricId
    )
  }

  // MARK: - 身份 / 音质工具

  /// identity.ts buildMusicId：`gd:v1:<gdSource>:<rawId>`（传入宿主源名时先规范化）
  static func buildHostId(source: String, rawId: String) -> String {
    "gd:v1:\(toGdSource(source) ?? source):\(rawId)"
  }

  /// identity.ts toGdSource：剥离 gd-/gd_ 前缀并校验 10 个已知源，非法返回 nil
  static func toGdSource(_ s: String) -> String? {
    let value = (s.hasPrefix("gd-") || s.hasPrefix("gd_")) ? String(s.dropFirst(3)) : s
    return gdSources.contains(value) ? value : nil
  }

  /// 复用 ALQualityBridge 的 br → 音质档声明
  static func buildQualitys(br: Int) -> [MusicQualityType] {
    ALQualityBridge.qualitys(fromBr: br)
  }
}
