import Foundation
import CryptoKit

// MARK: - 酷狗歌曲评论（原生迁移自 online-metadata 扩展，严格对齐）
//
// 参考（只读 submodule，逐行对照）：
//   extensions/online-metadata/src/onlineResource/kg/msuicComment.ts
//     · replaceAt (:14-20) / formatImages (:22-25) / buildCommentItem (:27-41)
//     · filterComment (:43-62) / buildParams (:64-67)
//     · getComment (:69-99) / getHotComment (:101-131) / getReplyComment (:133-161)
//     · musicComment (:163-184)
//   extensions/online-metadata/src/onlineResource/kg/utils.ts:12-19  (signatureParams)
//   extensions/online-metadata/src/onlineResource/kg/types/musicComment.d.ts
//   extensions/online-metadata/src/onlineResource/kg/types/musicCommentHot.d.ts
//
// 签名这里内联实现（与 ALCrypto.kgSignature(_:platform:) 同一算法）：utils.ts 的
// keyparam + 参数字典序拼接 + body + keyparam 后 MD5，platform 默认 android。

enum ALCommentKg {

  // MARK: - 对外入口（对应 musicComment.ts:163-184）

  /// type: "new" | "hot" | "reply"（reply 必须传 replyId，对应扩展的 options.id）
  static func comment(music: MusicInfo, type: String, replyId: String? = nil,
                      page: Int, limit: Int) async throws -> ALMusicCommentResult {
    let json: [String: Any]?
    switch type {
    case "new":
      json = try await fetchRank(music: music, endpoint: "newest", page: page, limit: limit)
    case "hot":
      json = try await fetchRank(music: music, endpoint: "topliked", page: page, limit: limit)
    case "reply":
      guard let replyId, !replyId.isEmpty else {
        throw ALSourceError.invalidResponse("酷狗回复评论需要 replyId")
      }
      json = try await fetchReply(music: music, replyId: replyId, page: page, limit: limit)
    default:
      throw ALSourceError.invalidResponse("酷狗评论类型无效：\(type)")
    }

    guard let json, ALHttp.int(json["err_code"]) == 0 else {
      throw ALSourceError.invalidResponse("酷狗评论失败")
    }
    return ALMusicCommentResult(
      list: filterComment(ALHttp.arr(json["list"])),
      total: ALHttp.int(json["count"]) ?? 0,
      limit: limit,
      page: page
    )
  }

  // MARK: - 请求（new / hot 共用签名参数；reply 为免签接口）

  /// m.comment.service.kugou.com/r/v1/rank/{newest,topliked}
  private static func fetchRank(music: MusicInfo, endpoint: String,
                                page: Int, limit: Int) async throws -> [String: Any]? {
    let hash = music.extra?["hash"] ?? music.extra?["hqHash"] ?? music.songmid
    let params = buildParams(hash: hash, page: page, limit: limit)
    let sig = signature(params, platform: "android")
    let url = "http://m.comment.service.kugou.com/r/v1/rank/\(endpoint)?\(params)&signature=\(sig)"
    let headers = ["User-Agent": edgeUA]
    return try await ALHttp.getJSON(url, headers: headers, requireOK: true) as? [String: Any]
  }

  /// comment.service.kugou.com/index.php?r=commentsv2/getReplyWithLike
  private static func fetchReply(music: MusicInfo, replyId: String,
                                 page: Int, limit: Int) async throws -> [String: Any]? {
    let childrenid = music.songmid // meta.musicId 即 iMusic 的 songmid（酷狗 audioId）
    let url = "http://comment.service.kugou.com/index.php?r=commentsv2/getReplyWithLike"
      + "&code=fc4be23b4e972707f36b8a828a93ba8a"
      + "&p=\(page)&pagesize=\(limit)&ver=1.01&clientver=8373&kugouid=687373022"
      + "&need_show_image=1&appid=1001&childrenid=\(childrenid)&tid=\(replyId)"
    let headers = ["User-Agent": androidUA]
    return try await ALHttp.getJSON(url, headers: headers, requireOK: true) as? [String: Any]
  }

  /// buildParams（msuicComment.ts:64-67），键顺序与字面量保持一致
  private static func buildParams(hash: String, page: Int, limit: Int) -> String {
    let clienttime = Int(Date().timeIntervalSince1970 * 1000)
    return "dfid=0&mid=16249512204336365674023395779019"
      + "&clienttime=\(clienttime)&uuid=0"
      + "&extdata=\(hash)&appid=1005"
      + "&code=fc4be23b4e972707f36b8a828a93ba8a"
      + "&schash=\(hash)&clientver=11409&p=\(page)"
      + "&clienttoken=&pagesize=\(limit)&ver=10&kugouid=0"
  }

  // MARK: - 签名（kg/utils.ts:12-19 signatureParams 的内联等价实现）

  private static func signature(_ params: String, platform: String = "android", body: String = "") -> String {
    let keyparam = platform == "web"
      ? "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt"
      : "OIlwieks28dk2k092lksi2UIkp"
    let sorted = params.split(separator: "&", omittingEmptySubsequences: false).map(String.init).sorted()
    return md5(keyparam + sorted.joined() + body + keyparam)
  }

  private static func md5(_ s: String) -> String {
    Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - 映射（msuicComment.ts:14-62）

  /// replaceAt：`[at=id]` → `@name `（对应 :28 的 item.atlist ? replaceAt(...) : content）
  private static func replaceAt(_ raw: String, _ atList: [[String: Any]]) -> String {
    var result = raw
    for at in atList {
      let id = ALHttp.str(at["id"])
      let name = ALHttp.str(at["name"])
      result = result.replacingOccurrences(of: "[at=\(id)]", with: "@\(name) ")
    }
    return result
  }

  /// formatImages：字符串数组取原值，对象数组取 url；非数组 → []
  private static func formatImages(_ raw: Any?) -> [String] {
    guard let list = raw as? [Any] else { return [] }
    return list.compactMap { item -> String? in
      if let s = item as? String { return s }
      if let d = item as? [String: Any] {
        let url = ALHttp.str(d["url"])
        return url.isEmpty ? nil : url
      }
      return nil
    }
  }

  /// buildCommentItem
  private static func buildComment(_ item: [String: Any]) -> ALMusicCommentItem {
    let atlist = item["atlist"] as? [[String: Any]] ?? []
    let content = ALFormat.decodeName(replaceAt(ALHttp.str(item["content"]), atlist))
    let addtimestamp = ALHttp.int(item["addtimestamp"]) ?? 0
    let like = item["like"] as? [String: Any]
    let avatar = ALHttp.str(item["user_pic"])
    return ALMusicCommentItem(
      id: ALHttp.str(item["id"]),
      userId: ALHttp.str(item["user_id"]),
      userName: ALFormat.decodeName(ALHttp.str(item["user_name"])),
      text: content,
      time: addtimestamp != 0 ? addtimestamp * 1000 : nil,
      images: formatImages(item["images"]),
      avatar: avatar.isEmpty ? nil : avatar,
      likedCount: like.flatMap { ALHttp.int($0["likenum"]) },
      reply: []
    )
  }

  /// filterComment：pcontent 存在时构造「父评论 + 单条回复」的嵌套结构
  private static func filterComment(_ raw: [[String: Any]]?) -> [ALMusicCommentItem] {
    guard let raw else { return [] }
    return raw.map { item in
      let data = buildComment(item)
      let pcontent = ALHttp.str(item["pcontent"])
      guard !pcontent.isEmpty else { return data }
      return ALMusicCommentItem(
        id: ALHttp.str(item["id"]),
        userId: ALHttp.str(item["puser_id"]),
        userName: ALFormat.decodeName(ALHttp.str(item["puser"])),
        text: ALFormat.decodeName(pcontent),
        time: nil,
        images: [],
        reply: [data]
      )
    }
  }

  // MARK: - UA

  private static let edgeUA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.24"
  private static let androidUA = "Android712-AndroidPhone-8983-18-0-COMMENT-wifi"
}
