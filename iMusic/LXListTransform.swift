import Foundation

// MARK: - LX 音乐列表 → any-listen 列表数据转换（原生迁移）
//
// 复刻自 any-listen 官方扩展 `lx-list-transform`（submodule extensions/lx-list-transform/src/shared/lx2al.ts）。
// 用途：把 LX Music（lx-music）导出的歌单备份（playList_v2 / playListPart_v2 / allData_v2）
// 转换为 any-listen 生态的 ListDataFull 备份格式（{ songlist: { version: 1, data } }）。
//
// 纯数据转换，无网络；输入为 LX 备份的 JSON，输出为 any-listen 备份 JSON 字符串。
// 与 TS 原版逐字段对齐：defaultList/loveList/userList、qualitys→sizeStr、flac32bit→flac24bit、
// kg 歌曲 id 加 `kg_` 前缀、online 歌单的 syncId/date 处理、按 id 去重、加歌位置 top/bottom。

enum LXListTransform {
  /// 加歌位置：top（追加在列表尾部，TS idx 从 count 递减 → 时间倒序） / bottom
  enum AddListType: String {
    case top
    case bottom
  }

  // MARK: 转换入口

  /// data.type: "playList_v2" | "playListPart_v2" | "allData_v2"
  /// 返回 any-listen 备份 JSON 字符串；不支持的 type 抛错。
  static func transform(type: String, data: Any, addListType: AddListType = .top) throws -> String {
    switch type {
    case "playList_v2":
      guard let arr = data as? [[String: Any]] else { throw LXListError.invalid("playList_v2 数据应为数组") }
      return try buildBackup(buildPlayList(arr, addListType: addListType))
    case "allData_v2":
      guard let obj = data as? [String: Any], let arr = obj["playList"] as? [[String: Any]] else {
        throw LXListError.invalid("allData_v2 数据应含 playList 数组")
      }
      return try buildBackup(buildPlayList(arr, addListType: addListType))
    case "playListPart_v2":
      guard let obj = data as? [String: Any] else { throw LXListError.invalid("playListPart_v2 数据应为对象") }
      return try buildBackup(buildListPart(obj, addListType: addListType))
    default:
      throw LXListError.unsupported(type)
    }
  }

  // MARK: 顶层组装

  private static func buildBackup(_ data: [String: Any]) throws -> String {
    let payload: [String: Any] = ["songlist": ["version": 1, "data": data]]
    let json = try JSONSerialization.data(withJSONObject: payload)
    return String(data: json, encoding: .utf8) ?? ""
  }

  /// 完整备份：前两条分别是 defaultList / loveList，其余为 userList
  private static func buildPlayList(_ data: [[String: Any]], addListType: AddListType) -> [String: Any] {
    var rest = data
    let defaultList = filterMusicList(rest.isEmpty ? [] : (rest.removeFirst()["list"] as? [[String: Any]] ?? []))
    let loveList = filterMusicList(rest.isEmpty ? [] : (rest.removeFirst()["list"] as? [[String: Any]] ?? []))
    let time = Date().timeIntervalSince1970 * 1000

    var out: [String: Any] = [:]
    out["defaultList"] = buildDefaultLikeList(id: "default", name: "default", list: defaultList, time: time, addListType: addListType)
    out["loveList"] = buildDefaultLikeList(id: "love", name: "love", list: loveList, time: time, addListType: addListType)
    out["userList"] = rest.map { buildUserList($0, addListType: addListType) }
    return out
  }

  /// 单个列表（歌单部分备份）：包装成 userList 数组
  private static func buildListPart(_ data: [String: Any], addListType: AddListType) -> [String: Any] {
    ["userList": [buildUserList(data, addListType: addListType)]]
  }

  // MARK: 列表构建

  /// default/love 这两个"默认列表"结构（TS 里的 defaultList/loveList 常量 + 填充）
  private static func buildDefaultLikeList(id: String, name: String, list: [[String: Any]],
                                           time: Double, addListType: AddListType) -> [String: Any] {
    var meta = metaBase()
    let count = list.count
    let songs = list.enumerated().compactMap { i, m -> [String: Any]? in
      buildMusicInfo(fixQuality(m), addListType: addListType, time: time, count: count, idx: i)
    }
    meta["songCount"] = songs.count
    return ["id": id, "name": name, "type": "default", "meta": meta, "parentId": NSNull(), "list": songs]
  }

  /// 用户歌单：有 sourceListId → online 类型（含 syncId/date），否则 general 类型
  private static func buildUserList(_ list: [String: Any], addListType: AddListType) -> [String: Any] {
    let time = Date().timeIntervalSince1970 * 1000
    let filtered = filterMusicList(list["list"] as? [[String: Any]] ?? [])
    let count = filtered.count
    let songs = filtered.enumerated().compactMap { i, m -> [String: Any]? in
      buildMusicInfo(fixQuality(m), addListType: addListType, time: time, count: count, idx: i)
    }

    if let sourceListId = list["sourceListId"] as? String {
      let source = ALHttp.str(list["source"])
      let isBoard = sourceListId.hasPrefix("board__")
      var meta = metaBase()
      meta["extensionId"] = "online-metadata"
      meta["source"] = source
      meta["sourceType"] = isBoard ? "topSongs" : "songlist"
      meta["pic"] = ""
      meta["syncId"] = isBoard ? sourceListId.replacingOccurrences(of: "board__\(source)__", with: "") : sourceListId
      meta["syncTime"] = 0
      if isBoard { meta["date"] = "" }
      meta["songCount"] = songs.count
      return ["id": genId(), "name": list["name"] as? String ?? "",
              "type": "online", "parentId": NSNull(), "meta": meta, "list": songs]
    }

    var meta = metaBase()
    meta["songCount"] = songs.count
    return ["id": genId(), "name": list["name"] as? String ?? "",
            "type": "general", "parentId": NSNull(), "meta": meta, "list": songs]
  }

  // MARK: 歌曲构建

  private static func metaBase() -> [String: Any] {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    return ["playCount": 0, "createTime": now, "updateTime": 0, "posTime": 0,
            "songCount": 0, "pic": "", "desc": ""]
  }

  /// 单条 LX 歌曲 → any-listen MusicInfoOnline（JSON 形式，与 TS 一致）
  private static func buildMusicInfo(_ lx: [String: Any], addListType: AddListType,
                                     time: Double, count: Int, idx: Int) -> [String: Any]? {
    guard let lxID = lx["id"] as? String, !lxID.isEmpty else { return nil }
    let createTime = time + (addListType == .top ? Double(count - idx) : Double(idx)) / Double(max(count, 1))
    let source = lx["source"] as? String ?? ""
    let lxMeta = lx["meta"] as? [String: Any] ?? [:]

    if source == "local" {
      let isLocalMeta: [String: Any] = [
        "albumName": lxMeta["albumName"] as? String ?? "",
        "musicId": lxID,
        "createTime": Int(createTime), "posTime": Int(createTime), "updateTime": Int(createTime),
        "sizeStr": "", "picUrl": lxMeta["picUrl"] as? String ?? "",
        "bitrateLabel": "", "deviceId": "", "ext": lxMeta["ext"] as? String ?? "",
        "filePath": lxMeta["filePath"] as? String ?? "",
      ]
      return ["id": lxID, "name": lx["name"] ?? "", "singer": lx["singer"] ?? "",
              "isLocal": true, "interval": lx["interval"] ?? "", "meta": isLocalMeta]
    }

    // 剥离 qualitys/_qualitys 两个键，其余 data 进入 meta
    var data = lxMeta
    let _qualitys = data["_qualitys"] as? [String: Any] ?? [:]
    data.removeValue(forKey: "qualitys")
    data.removeValue(forKey: "_qualitys")

    var meta: [String: Any] = data
    meta["source"] = source
    // TS: String(meta.id || meta.songId)；后续按 songId/id 再覆盖
    meta["musicId"] = String(ALHttp.int(lxMeta["id"]) ?? ALHttp.int(lxMeta["songId"]) ?? 0)
    meta["qualitys"] = buildQualitys(_qualitys)
    meta["createTime"] = Int(createTime)
    meta["posTime"] = Int(createTime)
    meta["updateTime"] = Int(createTime)

    var info: [String: Any] = [
      "id": lxID, "name": lx["name"] ?? "", "singer": lx["singer"] ?? "",
      "isLocal": false, "interval": lx["interval"] ?? "", "meta": meta,
    ]

    if source == "kg" {
      info["id"] = "kg_\(lxID)"
    }
    if let songId = lxMeta["songId"] {
      info["meta"] = merged(meta, ["musicId": String(ALHttp.int(songId) ?? ALHttp.int(lxMeta["id"]) ?? 0)])
    }
    if let id = lxMeta["id"] {
      info["meta"] = merged(info["meta"] as? [String: Any] ?? [:], ["songId": String(ALHttp.int(id) ?? 0)])
    }
    return info
  }

  private static func merged(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
    var m = a; for (k, v) in b { m[k] = v }; return m
  }

  /// LX `_qualitys` `{type: {size, ...}}` → any-listen `{type: {sizeStr, ...}}`
  private static func buildQualitys(_ lx: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in lx {
      guard var o = v as? [String: Any] else { continue }
      let size = o["size"]
      o.removeValue(forKey: "size")
      o["sizeStr"] = size
      out[k] = o
    }
    return out
  }

  /// flac32bit 归一为 flac24bit（LX 老备份质量档名）
  private static func fixQuality(_ music: [String: Any]) -> [String: Any] {
    guard let source = music["source"] as? String, source != "local",
          var meta = music["meta"] as? [String: Any] else { return music }
    var _qualitys = meta["_qualitys"] as? [String: Any] ?? [:]
    if _qualitys["flac32bit"] != nil && _qualitys["flac24bit"] == nil {
      _qualitys["flac24bit"] = _qualitys["flac32bit"]
      _qualitys.removeValue(forKey: "flac32bit")
      meta["_qualitys"] = _qualitys
      // 同步 qualitys 数组里的档位名
      if var qs = meta["qualitys"] as? [[String: Any]] {
        for i in qs.indices where (qs[i]["type"] as? String) == "flac32bit" {
          qs[i]["type"] = "flac24bit"
        }
        meta["qualitys"] = qs
      }
    }
    var out = music
    out["meta"] = meta
    return out
  }

  /// 按 id 去重；缺 id 或缺 name 的条目剔除；singer 缺省空串
  private static func filterMusicList(_ list: [[String: Any]]) -> [[String: Any]] {
    var seen = Set<String>()
    var out: [[String: Any]] = []
    for var s in list {
      guard let id = s["id"] as? String, !id.isEmpty,
            !seen.contains(id), s["name"] != nil else { continue }
      seen.insert(id)
      if s["singer"] == nil { s["singer"] = "" }
      out.append(s)
    }
    return out
  }

  private static func genId() -> String {
    String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<1_000_000), radix: 36)
  }

  enum LXListError: LocalizedError {
    case invalid(String)
    case unsupported(String)
    var errorDescription: String? {
      switch self {
      case .invalid(let m): return "LX 列表数据无效：\(m)"
      case .unsupported(let t): return "不支持的文件类型：\(t)"
      }
    }
  }
}