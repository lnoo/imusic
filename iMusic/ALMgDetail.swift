import Foundation

// MARK: - 咪咕音乐详情（ALMgDetail）
//
// 补齐 MG 缺失的 musicDetail REST 层，只读参考（submodule 一律不改）：
//   extensions/online-metadata/src/onlineResource/mg/musicDetail.ts  POST resourceinfo.do
//     · resourceId = ids.join('|')，每批 100 条并行；code ?? returnCode === '000000'
//   extensions/online-metadata/src/onlineResource/mg/utils/index.ts
//     buildMusicInfoList  : songId 去重 / newRateFormats(size??androidSize) /
//                           albumImgs[0].img / artists → 音质档 + meta 字段
//     buildMusicInfoListV5: audioFormats(isize??asize) / img3||img2||img1 /
//                           singerList / duration → 音质档 + meta 字段
//   本层兼容两种字段形态（详情接口实测两者均可能出现），按 songId 去重。
//
// 对外 API（供 ALWordLyric.mgLyric / AnyListenResource.musicPic 接线）：
//   ALMgDetail.musicDetail(ids:)      批量详情 → [MusicInfo]
//   ALMgDetail.ensureLyricInfo(_:)     mrcUrl 缺失时补取详情并合并 meta
//   ALMgDetail.pic(for:)              动态封面（详情 meta.picUrl）
//   ALMgDetail.qualitys(for:)         详情声明的音质档（可选兜底）

enum ALMgDetail {
  private static let detailURL = "https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2"
  private static let batchSize = 100
  private static let imageHost = "http://d.musicapp.migu.cn"

  // MARK: 对外 API

  /// 批量音乐详情：按 100 一批并行请求，按 songId 去重。
  static func musicDetail(ids: [String]) async throws -> [MusicInfo] {
    guard !ids.isEmpty else { return [] }

    let batches = stride(from: 0, to: ids.count, by: batchSize).map { start in
      Array(ids[start..<min(start + batchSize, ids.count)])
    }

    // 在子任务内完成 JSON → MusicInfo 映射：避免 [[String: Any]]（Any 非 Sendable）
    // 跨越 task 边界；MusicInfo 为 Sendable。
    var infos: [MusicInfo] = []
    try await withThrowingTaskGroup(of: [MusicInfo].self) { group in
      for batch in batches {
        group.addTask {
          let resources = try await Self.requestBatch(batch)
          return resources.compactMap(Self.mapResource)
        }
      }
      for try await part in group {
        infos.append(contentsOf: part)
      }
    }
    return ALNormalize.dedup(infos) { $0.songmid }
  }

  /// 确保歌词 meta 可用：已有 mrcUrl 时直接返回；否则按 songmid 补取详情，
  /// 将 mrcUrl/contentId/lrcUrl/trcUrl 合并进副本返回（取不到详情返回 nil）。
  static func ensureLyricInfo(_ music: MusicInfo) async -> MusicInfo? {
    if let mrcUrl = music.extra?["mrcUrl"], !mrcUrl.isEmpty { return music }

    guard let meta = try? await musicDetail(ids: [music.songmid]).first else { return nil }

    var copy = music
    var extra = copy.extra ?? [:]
    for key in ["mrcUrl", "contentId", "lrcUrl", "trcUrl"] {
      if let value = meta.extra?[key], !value.isEmpty { extra[key] = value }
    }
    copy.extra = extra
    return copy
  }

  /// 动态封面：详情接口 meta.picUrl（对标 mg/pic.ts getPic）。
  static func pic(for music: MusicInfo) async -> String? {
    let infos = try? await musicDetail(ids: [music.songmid])
    return infos?.first?.picUrl
  }

  /// 详情声明的音质档；取不到详情时沿用音乐已有声明。
  static func qualitys(for music: MusicInfo) async -> [MusicQualityType] {
    let infos = try? await musicDetail(ids: [music.songmid])
    return infos?.first?.qualitys ?? music.qualitys
  }

  // MARK: 请求

  private static func requestBatch(_ ids: [String]) async throws -> [[String: Any]] {
    let json = try await ALHttp.postForm(
      detailURL,
      form: [("resourceId", ids.joined(separator: "|"))],
      headers: ["channel": "0146921"])
    guard let body = json as? [String: Any] else {
      throw ALSourceError.invalidResponse("咪咕音乐详情响应异常")
    }

    // body.code ?? body.returnCode（兼容 NSNull，对齐 JS 空值合并）
    var codeRaw = body["code"]
    if let value = codeRaw, value is NSNull { codeRaw = nil }
    if codeRaw == nil { codeRaw = body["returnCode"] }
    let code = ALHttp.str(codeRaw)
    guard code == "000000" else {
      throw ALSourceError.invalidResponse("咪咕音乐详情失败：\(ALHttp.str(body["info"]))")
    }
    return ALHttp.arr(body["resource"]) ?? []
  }

  // MARK: 映射（buildMusicInfoList + V5 兼容）

  private static func mapResource(_ item: [String: Any]) -> MusicInfo? {
    guard let songId = item["songId"] as? String, !songId.isEmpty else { return nil }

    // 音质：audioFormats(isize??asize) 优先，回退 newRateFormats(size??androidSize)
    let v5Formats = item["audioFormats"] as? [[String: Any]] ?? []
    let legacyFormats = item["newRateFormats"] as? [[String: Any]] ?? []
    let useV5 = !v5Formats.isEmpty
    var quals: [MusicQualityType] = []
    for format in (useV5 ? v5Formats : legacyFormats) {
      let rawSize = useV5 ? (format["isize"] ?? format["asize"])
                          : (format["size"] ?? format["androidSize"])
      guard (ALHttp.int(rawSize) ?? 0) > 0 else { continue }
      let size = ALFormat.sizeFormate(rawSize)
      switch ALHttp.str(format["formatType"]) {
      case "PQ": quals.append(.init(type: .q128k, size: size))
      case "HQ": quals.append(.init(type: .q320k, size: size))
      case "SQ": quals.append(.init(type: .flac, size: size))
      case "ZQ", "ZQ24": quals.append(.init(type: .flac24bit, size: size))
      default: break
      }
    }

    // 封面：img3||img2||img1，回退 albumImgs[0].img；相对路径补 migu 域名
    var img = ALHttp.str(item["img3"])
    if img.isEmpty { img = ALHttp.str(item["img2"]) }
    if img.isEmpty { img = ALHttp.str(item["img1"]) }
    if img.isEmpty {
      img = (item["albumImgs"] as? [[String: Any]])?.first
        .flatMap { $0["img"] as? String } ?? ""
    }
    if !img.isEmpty, !img.hasPrefix("http") { img = imageHost + img }

    // 歌手：singerList(V5) → artists(detail) → singer 字符串
    let singers: String = {
      if let list = item["singerList"] as? [[String: Any]] {
        return ALFormat.singerName(list, key: "name")
      }
      if let list = item["artists"] as? [[String: Any]] {
        return ALFormat.singerName(list, key: "name")
      }
      if let list = item["singerList"] as? [String] {
        return ALFormat.decodeName(list.joined(separator: "、"))
      }
      return ALFormat.decodeName(ALHttp.str(item["singer"]))
    }()

    // 时长：duration 秒 → ALFormat.playTime；否则取 length 尾部 mm:ss
    var interval: String? = nil
    if let secs = ALHttp.int(item["duration"]), secs > 0 {
      interval = ALFormat.playTime(secs)
    } else {
      let length = ALHttp.str(item["length"])
      if let regex = try? NSRegularExpression(pattern: #"(\d\d:\d\d)$"#),
         let match = regex.firstMatch(in: length, range: NSRange(location: 0, length: (length as NSString).length)) {
        interval = (length as NSString).substring(with: match.range(at: 1))
      }
    }

    let lrcUrl = ALHttp.str(item["lrcUrl"])
    let mrcUrl = ALHttp.str(item["mrcUrl"])
    let trcUrl = ALHttp.str(item["trcUrl"])
    var extra: [String: String] = [
      "copyrightId": ALHttp.str(item["copyrightId"]),
      "albumId": ALHttp.str(item["albumId"]),
      "contentId": ALHttp.str(item["contentId"]),
      "lrcUrl": lrcUrl, "mrcUrl": mrcUrl, "trcUrl": trcUrl,
    ]
    if let secs = ALHttp.int(item["duration"]) { extra["intervalSecs"] = "\(secs)" }

    return MusicInfo(
      name: ALFormat.decodeName(ALHttp.str(item["songName"])),
      singer: singers,
      source: .mg,
      songmid: songId,
      albumName: ALFormat.decodeName(ALHttp.str(item["album"])),
      interval: interval,
      qualitys: quals,
      picUrl: img.isEmpty ? nil : img,
      extra: extra)
  }
}
