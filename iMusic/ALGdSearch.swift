import Foundation

// MARK: - GD音乐台搜索（分页 + 搜索结果信息补全）
//
// 移植自只读 submodule extensions/gdstudio（不改动 submodule 任何文件）：
//   src/shared/searchPagination.ts:1-54          createSearchPagination / getPage
//   src/index.ts:637-732                         searchCache / fetchSearchBatch / musicSearch
//   src/index.ts:484-510                         detectMainApiQuality / hydrateMainApiSearchItem
//   src/index.ts:452-482                         fetchMusicPic
//   src/index.ts:113-148                         qualityToBr / brToQuality / buildQualitysFromBr
//
// `source` 是原始 gd 源名（netease/kuwo/tencent/joox/tidal/qobuz/bilibili/apple/ytmusic/spotify）。
// org 系列源（以及 useOrgSource 开启时的全部源）只走签名服务器；搜索界面绝不嗅探签名 API，
// 避免每次签名都占用上游配额而触发限流。

enum ALGdSearch {
  // MARK: - 对外入口

  /// GD音乐台搜索：按 (source, name, artist, limit) 复用分页器，返回指定页。
  static func search(source: String, name: String, artist: String?, page: Int, limit: Int) async throws -> ALListResult<MusicInfo> {
    // gdstudio musicSearch: `page || 1`、`Math.min(limit || 20, 50)`
    let normalizedPage = max(1, page)
    let requestedLimit = limit == 0 ? 20 : limit
    let pageSize = max(1, min(requestedLimit, 50))

    // org 音源未配置签名服务器：立即报错，不进重试/缓存流程
    guard !ALGdSign.isOrgSource(source) || ALGdSign.hasConfig else {
      throw ALSourceError.invalidResponse("当前音源尚未配置")
    }

    let key = "\(source)|\(name)|\(artist ?? "")|\(pageSize)"
    let pagination: GdSearchPagination = cacheBox.lock.withLock {
      if let entry = cacheBox.entry, entry.key == key { return entry.pagination }
      let queryName = (artist?.isEmpty == false) ? "\(name) \(artist!)" : name
      let fresh = GdSearchPagination(source: source, name: queryName, count: pageSize * 3)
      cacheBox.entry = CacheEntry(key: key, pagination: fresh)
      return fresh
    }

    let result = try await pagination.getPage(page: normalizedPage, limit: pageSize)
    let list = ALGdSign.isOrgSource(source) ? result.list : await hydrate(result.list, source: source)
    return ALListResult(list: list, total: result.total, page: normalizedPage, limit: pageSize)
  }

  /// 补全搜索结果音质档与封面（非 org 源主 API 探测；org 源整体跳过）。
  static func hydrate(_ items: [MusicInfo], source: String) async -> [MusicInfo] {
    // 搜索界面严禁嗅探签名 API：org 源直接原样返回
    guard !ALGdSign.isOrgSource(source) else { return items }

    var result = items
    await withTaskGroup(of: (Int, MusicInfo?).self) { group in
      for (index, item) in items.enumerated() {
        group.addTask {
          var extra = item.extra ?? [:]
          if extra["_detailsLoaded"] == "1" { return (index, nil) }

          let musicId: String = {
            if let raw = extra["musicId"],
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return raw }
            return item.songmid
          }()

          let picId = extra["_picId"]
          async let br = probeQuality(source: source, musicId: musicId)
          async let pic = probePic(source: source, picId: picId)
          let actualBr = await br
          let picUrl = await pic

          extra["_detailsLoaded"] = "1"
          var updated = item
          updated.extra = extra
          if let actualBr { updated.qualitys = ALQualityBridge.qualitys(fromBr: actualBr) }
          if let picUrl { updated.picUrl = picUrl }
          return (index, updated)
        }
      }
      for await (index, updated) in group {
        if let updated { result[index] = updated }
      }
    }
    return result
  }

  // MARK: - 搜索缓存
  //
  // 单个进程内缓存（对标 gdstudio 模块级 `searchCache`）。Swift 6 下用 NSLock 保护
  // 唯一可变槽位：锁内只做值类型读写，分页器本身是 actor（Sendable），可安全跨并发域传递。
  // 不持久化、不迁移旧缓存。

  private struct CacheEntry {
    let key: String
    let pagination: GdSearchPagination
  }

  private final class CacheBox: @unchecked Sendable {
    let lock = NSLock()
    var entry: CacheEntry?
  }

  private static let cacheBox = CacheBox()

  // MARK: - 分页器（对标 createSearchPagination）
  //
  // 累积去重后的结果；`nextApiPage` 从 1 开始。同一时刻只有一个批次抓取在飞行中：
  // 并发的 getPage 共享同一个 pending Task，批次抓取与状态写入只执行一次。
  // 任一批次空结果视为限流并抛错；整页重复（无新增 id）则标记 exhausted。

  private actor GdSearchPagination {
    private struct PendingFetch {
      let id: Int
      let task: Task<Void, Error>
    }

    private let source: String
    private let name: String
    private let count: Int

    private var items: [MusicInfo] = []
    private var ids: Set<String> = []
    private var nextApiPage = 1
    private var exhausted = false
    private var pending: PendingFetch?
    private var nextFetchID = 0

    init(source: String, name: String, count: Int) {
      self.source = source
      self.name = name
      self.count = count
    }

    func getPage(page: Int, limit: Int) async throws -> (list: [MusicInfo], total: Int) {
      let start = (page - 1) * limit
      let end = start + limit
      do {
        while items.count < end && !exhausted {
          try await loadNextBatch()
        }
      } catch {
        // 部分失败：已有结果覆盖本页起点则保留（下一页可重试），否则向上抛错。
        if start >= items.count { throw error }
      }

      let from = min(max(start, 0), items.count)
      let to = min(max(end, from), items.count)
      // 短批次不代表末页：未耗尽时多对外 advertise 一页，保证向后翻页入口存在。
      let total = exhausted ? items.count : ((items.count + limit - 1) / limit) * limit + 1
      return (Array(items[from..<to]), total)
    }

    private func loadNextBatch() async throws {
      let entry: PendingFetch
      if let pending {
        entry = pending
      } else {
        nextFetchID += 1
        // Task 继承当前 actor 隔离：抓取与写入只发生一次，所有等待者共享结果。
        let task = Task {
          try await self.fetchAndAppend()
        }
        entry = PendingFetch(id: nextFetchID, task: task)
        pending = entry
      }

      do {
        try await entry.task.value
      } catch {
        if pending?.id == entry.id { pending = nil }
        throw error
      }
      if pending?.id == entry.id { pending = nil }
    }

    private func fetchAndAppend() async throws {
      let apiPage = nextApiPage
      let batch = try await ALGdSearch.fetchSearchBatch(
        source: source, name: name, page: apiPage, count: count
      )
      guard !batch.isEmpty else {
        throw ALSourceError.invalidResponse("搜索返回空结果(可能是 API 限流,请稍后重试)")
      }

      var fresh: [MusicInfo] = []
      for item in batch where ids.insert(item.songmid).inserted {
        fresh.append(item)
      }
      // 部分源忽略 page 参数并重复同一批结果 → 视作耗尽
      if fresh.isEmpty { exhausted = true }
      items.append(contentsOf: fresh)
      nextApiPage += 1
    }
  }

  // MARK: - 批次抓取（对标 fetchSearchBatch）
  //
  // 最多 2 次尝试：空结果 300ms 后重试；抛错则 500ms 后重试；`error` 字段立即中止。
  // org 源走签名服务器（ALGdSign.call），其余走主 API（与 AnyListenGD 同入口/请求头）。

  fileprivate static func fetchSearchBatch(source: String, name: String, page: Int, count: Int) async throws -> [MusicInfo] {
    var lastError: String?
    for retry in 0..<2 {
      do {
        let json: Any
        if ALGdSign.isOrgSource(source) {
          json = try await ALGdSign.call(
            types: "search", source: source,
            extra: ["count": "\(count)", "pages": "\(page)", "name": name]
          )
        } else {
          json = try await mainAPI(types: "search", params: [
            "count": "\(count)", "source": source, "pages": "\(page)", "name": name,
          ])
        }

        if let dict = ALHttp.dict(json), let raw = dict["error"], !ALHttp.str(raw).isEmpty {
          lastError = ALHttp.str(raw)
          break
        }
        let rawList = ALHttp.arr(json) ?? []
        if !rawList.isEmpty {
          return rawList.map { mapSearchItem($0, source: source) }
        }
        if retry < 1 { await delay(300) }
      } catch {
        lastError = errorMessage(error)
        if retry < 1 { await delay(500) }
      }
    }
    throw ALSourceError.invalidResponse(
      lastError ?? "搜索返回空结果(可能是 API 限流,请稍后重试)"
    )
  }

  /// 非 org 源主 API（music-api.gdstudio.xyz）；入口与请求头复用 AnyListenGD。
  private static func mainAPI(types: String, params: [String: String]) async throws -> Any {
    let query = params.map { key, value in
      "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
    }.joined(separator: "&")
    return try await ALHttp.getJSON(
      "\(AnyListenGD.api)?types=\(types)&\(query)", headers: AnyListenGD.headers()
    )
  }

  // MARK: - 信息补全探测（对标 detectMainApiQuality / fetchMusicPic）

  /// types=url&br=999：有 url 才采信 br，否则回退 128；任何失败都吞掉。
  private static func detectMainApiQuality(source: String, musicId: String) async -> Int? {
    guard let json = try? await mainAPI(
      types: "url", params: ["source": source, "id": musicId, "br": "999"]
    ),
          let dict = ALHttp.dict(json),
          let url = dict["url"] as? String, !url.isEmpty
    else { return 128 }
    return ALHttp.int(dict["br"]) ?? 128
  }

  private static func probeQuality(source: String, musicId: String) async -> Int? {
    guard ALGdSign.preloadQualityOnSearch else { return nil }
    return await detectMainApiQuality(source: source, musicId: musicId)
  }

  /// types=pic&id=<_picId>&size=500；无 picId 或失败返回 nil。
  private static func probePic(source: String, picId: String?) async -> String? {
    guard let picId, !picId.isEmpty else { return nil }
    guard let json = try? await mainAPI(
      types: "pic", params: ["source": source, "id": picId, "size": "500"]
    ),
          let dict = ALHttp.dict(json),
          let url = dict["url"] as? String, !url.isEmpty
    else { return nil }
    return url
  }

  // MARK: - 映射 / 小工具

  /// gdstudio buildMusicInfo（与 AnyListenGD.mapSearchItem 同字段）。
  private static func mapSearchItem(_ item: [String: Any], source src: String) -> MusicInfo {
    let gid = ALHttp.str(item["id"])
    var interval: String? = nil
    let dur = ALHttp.double(item["duration"]) ?? ALHttp.double(item["interval"]) ?? 0
    if dur > 0 { interval = ALNormalize.formatInterval(Int(dur)) }
    var extra: [String: String] = ["_gdResourceVersion": "1"]
    if let picId = item["pic_id"] { extra["_picId"] = ALHttp.str(picId) }
    if let lyricId = item["lyric_id"] { extra["_lyricId"] = ALHttp.str(lyricId) }
    let br = ALHttp.int(item["br"]) ?? ALHttp.int(item["maxbr"]) ?? 128
    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(item["name"])),
      singer: ALNormalize.parseArtist(item["artist"]),
      source: source(fromGd: src),
      songmid: gid,
      albumName: ALFormat.decodeName(ALHttp.str(item["album"])),
      interval: interval,
      qualitys: ALQualityBridge.qualitys(fromBr: br),
      picUrl: nil,
      extra: extra
    )
  }

  /// GD 源名 → iMusic MusicSource（AnyListenGD.sourceName 的逆映射）。
  private static func source(fromGd s: String) -> MusicSource {
    switch s {
    case "netease": return .wy
    case "tencent": return .tx
    case "kuwo": return .kw
    case "joox": return .gdJoox
    case "tidal": return .gdTidal
    case "qobuz": return .gdQobuz
    case "bilibili": return .gdBilibili
    case "apple": return .gdApple
    case "ytmusic": return .gdYtmusic
    case "spotify": return .gdSpotify
    default: return .local
    }
  }

  private static func errorMessage(_ error: Error) -> String {
    if let gd = error as? ALSourceError, case .invalidResponse(let message) = gd { return message }
    return error.localizedDescription
  }

  private static func delay(_ milliseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
  }
}
