import Foundation

// MARK: - 网易云评论（ALCommentWy）
//
// 严格对齐 extensions/online-metadata/src/onlineResource/wy/musicComment.ts：
//   getComment       weapi POST /weapi/comment/resource/comments/get（new）
//                    参数对齐 musicComment.ts:199-217（rid/threadId/orderType/pageNo/pageSize/offset）
//   getHotComment    weapi POST /weapi/v1/resource/hotcomments/R_SO_4_<songId>（hot）
//                    参数对齐 musicComment.ts:234-239（rid/limit/offset/beforeTime）
//   formatReplyComment / filterHotComment：musicComment.ts:138-183
//   reply 分支       扩展直接 throw new Error('reply comment is not supported yet')
//                    → ALSourceError.unsupported(.wy)
//   表情映射          musicComment.ts:5-71
//   请求头/表单       对齐 wy/utils/index.ts weapiRequest + wy/utils/crypto.ts weapi
//
// 差异说明：扩展用模块级可变 cursorCache（musicComment.ts:73-130）做 new 分页，
// Swift 6 不允许非 Sendable 的全局可变状态，故不持有跨调用缓存，改用
// offset = limit * (page - 1) + pageNo 派生分页。「reply」不支持，与扩展一致。

enum ALCommentWy {

  // MARK: - 表情映射（musicComment.ts:5-71）

  private static let emojis: [(String, String)] = [
    ("大笑", "😃"), ("可爱", "😊"), ("憨笑", "☺️"), ("色", "😍"),
    ("亲亲", "😙"), ("惊恐", "😱"), ("流泪", "😭"), ("亲", "😚"),
    ("呆", "😳"), ("哀伤", "😔"), ("呲牙", "😁"), ("吐舌", "😝"),
    ("撇嘴", "😒"), ("怒", "😡"), ("奸笑", "😏"), ("汗", "😓"),
    ("痛苦", "😖"), ("惶恐", "😰"), ("生病", "😨"), ("口罩", "😷"),
    ("大哭", "😂"), ("晕", "😵"), ("发怒", "👿"), ("开心", "😄"),
    ("鬼脸", "😜"), ("皱眉", "😞"), ("流感", "😢"), ("爱心", "❤️"),
    ("心碎", "💔"), ("钟情", "💘"), ("星星", "⭐️"), ("生气", "💢"),
    ("便便", "💩"), ("强", "👍"), ("弱", "👎"), ("拜", "🙏"),
    ("牵手", "👫"), ("跳舞", "👯‍♀️"), ("禁止", "🙅‍♀️"), ("这边", "💁‍♀️"),
    ("爱意", "💏"), ("示爱", "👩‍❤️‍👨"), ("嘴唇", "👄"), ("狗", "🐶"),
    ("猫", "🐱"), ("猪", "🐷"), ("兔子", "🐰"), ("小鸡", "🐤"),
    ("公鸡", "🐔"), ("幽灵", "👻"), ("圣诞", "🎅"), ("外星", "👽"),
    ("钻石", "💎"), ("礼物", "🎁"), ("男孩", "👦"), ("女孩", "👧"),
    ("蛋糕", "🎂"), ("18", "🔞"), ("圈", "⭕"), ("叉", "❌"),
  ]

  /// applyEmoji（musicComment.ts:68-71）：[表情名] → emoji
  private static func applyEmoji(_ text: String) -> String {
    var out = text
    for (name, emoji) in emojis {
      out = out.replacingOccurrences(of: "[\(name)]", with: emoji)
    }
    return out
  }

  // MARK: - 入口

  /// 对齐 musicComment.ts:251-272。type: "new" | "hot" | "reply"
  static func comment(music: MusicInfo, type: String, page: Int, limit: Int) async throws -> ALMusicCommentResult {
    // musicComment.ts:132-136 getSongId：优先 extra.songId，回退 songmid
    let songId = Int(music.extra?["songId"] ?? music.songmid) ?? 0
    let rid = "R_SO_4_\(songId)"

    switch type {
    case "new":
      // musicComment.ts:199-207（cursor/缓存以 offset + pageNo 派生替代）
      let object: [String: Any] = [
        "offset": limit * (page - 1),
        "orderType": 1,
        "pageNo": page,
        "pageSize": limit,
        "rid": rid,
        "threadId": rid,
      ]
      let body = try await weapiPost("https://music.163.com/weapi/comment/resource/comments/get", object: object)
      guard ALHttp.int(body["code"]) == 200, let data = ALHttp.dict(body["data"]) else {
        throw ALSourceError.invalidResponse("网易评论失败")
      }
      return ALMusicCommentResult(
        list: filterComment(ALHttp.arr(data["comments"]) ?? []),
        total: ALHttp.int(data["totalCount"]) ?? 0,
        limit: limit, page: page)

    case "hot":
      // musicComment.ts:234-239
      let object: [String: Any] = [
        "rid": rid,
        "limit": limit,
        "offset": limit * (page - 1),
        "beforeTime": "\(Int(Date().timeIntervalSince1970 * 1000))",
      ]
      let body = try await weapiPost("https://music.163.com/weapi/v1/resource/hotcomments/\(rid)", object: object)
      guard ALHttp.int(body["code"]) == 200 else {
        throw ALSourceError.invalidResponse("网易热评失败")
      }
      return ALMusicCommentResult(
        list: filterHotComment(ALHttp.arr(body["hotComments"]) ?? []),
        total: ALHttp.int(body["total"]) ?? 0,
        limit: limit, page: page)

    case "reply":
      // 扩展 reply 分支直接抛错（musicComment.ts:264-266）
      throw ALSourceError.unsupported(.wy)

    default:
      throw ALSourceError.invalidResponse("网易评论类型无效：\(type)")
    }
  }

  // MARK: - 条目格式化（musicComment.ts:138-183）

  /// formatReplyComment：若 beReplied[0] 存在，外层为被回复评论，当前评论放入 reply[0]
  private static func formatReplyComment(_ item: [String: Any]) -> ALMusicCommentItem? {
    guard item["commentId"] != nil else { return nil }
    let user = ALHttp.dict(item["user"]) ?? [:]
    let data = makeItem(
      id: ALHttp.str(item["commentId"]),
      userId: ALHttp.str(user["userId"]),
      userName: ALFormat.decodeName(ALHttp.str(user["nickname"])),
      text: commentText(item["content"]),
      time: commentTime(item["time"]),
      location: optStr((ALHttp.dict(item["ipLocation"]) ?? [:])["location"]),
      avatar: optStr(user["avatarUrl"]),
      likedCount: ALHttp.int(item["likedCount"]),
      reply: [])

    if let replyData = (ALHttp.arr(item["beReplied"]) ?? []).first {
      let ru = ALHttp.dict(replyData["user"]) ?? [:]
      return makeItem(
        id: data.id,
        userId: ALHttp.str(ru["userId"]),
        userName: ALFormat.decodeName(ALHttp.str(ru["nickname"])),
        text: commentText(replyData["content"]),
        time: data.time, // 注意：时间取外层 item.time（对齐 :158）
        location: optStr((ALHttp.dict(replyData["ipLocation"]) ?? [:])["location"]),
        avatar: optStr(ru["avatarUrl"]),
        likedCount: nil, // 对齐 :161
        reply: [data])
    }
    return data
  }

  /// filterHotComment：热评不处理 beReplied，直接平铺（对齐 :171-183）
  private static func formatHotComment(_ item: [String: Any]) -> ALMusicCommentItem? {
    guard item["commentId"] != nil else { return nil }
    let user = ALHttp.dict(item["user"]) ?? [:]
    return makeItem(
      id: ALHttp.str(item["commentId"]),
      userId: ALHttp.str(user["userId"]),
      userName: ALFormat.decodeName(ALHttp.str(user["nickname"])),
      text: commentText(item["content"]),
      time: commentTime(item["time"]),
      location: optStr((ALHttp.dict(item["ipLocation"]) ?? [:])["location"]),
      avatar: optStr(user["avatarUrl"]),
      likedCount: ALHttp.int(item["likedCount"]),
      reply: [])
  }

  /// content ? applyEmoji(content) : ''（再走通用 HTML 实体解码，与解析层其它源一致）
  private static func commentText(_ v: Any?) -> String {
    let s = ALHttp.str(v)
    return s.isEmpty ? "" : ALFormat.decodeName(applyEmoji(s))
  }

  /// time || undefined：0 视为 nil
  private static func commentTime(_ v: Any?) -> Int? {
    guard let t = ALHttp.int(v), t != 0 else { return nil }
    return t
  }

  private static func optStr(_ v: Any?) -> String? {
    let s = ALHttp.str(v)
    return s.isEmpty ? nil : s
  }

  /// 集中补齐 ALMusicCommentItem 的全部字段（其余保持 nil）
  private static func makeItem(
    id: String,
    userId: String? = nil,
    userName: String,
    text: String,
    time: Int? = nil,
    location: String? = nil,
    avatar: String? = nil,
    likedCount: Int? = nil,
    reply: [ALMusicCommentItem]? = nil
  ) -> ALMusicCommentItem {
    ALMusicCommentItem(
      id: id, userId: userId, userName: userName, text: text, time: time,
      images: nil, location: location, avatar: avatar, likedCount: likedCount,
      skipPage: nil, replyTotal: nil, reply: reply, replySkipPage: nil)
  }

  private static func filterComment(_ raw: [[String: Any]]) -> [ALMusicCommentItem] {
    raw.compactMap(formatReplyComment)
  }

  private static func filterHotComment(_ raw: [[String: Any]]) -> [ALMusicCommentItem] {
    raw.compactMap(formatHotComment)
  }

  // MARK: - weapi POST（对齐 wy/utils/index.ts weapiRequest + crypto.ts weapi）

  private static func weapiPost(_ url: String, object: [String: Any]) async throws -> [String: Any] {
    let enc = ALCrypto.weapiParams(object, url: url)
    guard let u = URL(string: url) else { throw ALSourceError.invalidResponse("网易评论 URL 无效") }

    var req = URLRequest(url: u, timeoutInterval: 15)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
                 forHTTPHeaderField: "User-Agent")
    req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
    req.setValue("https://music.163.com", forHTTPHeaderField: "Origin")

    // weapi 的 params/encSecKey 常为 base64（含 + / =），必须严格百分号编码，
    // 否则服务端会把 + 解成空格导致解密失败。
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let fields = [
      "params=\(enc.params.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")",
      "encSecKey=\(enc.encSecKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")",
    ]
    req.httpBody = Data(fields.joined(separator: "&").utf8)

    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw ALSourceError.invalidResponse("网易评论 HTTP \(status)") }
    return try parseBody(data)
  }

  /// 扩展 weapiRequest 在 body 为字符串时 JSON.parse 再返回；这里等价兼容
  private static func parseBody(_ data: Data) throws -> [String: Any] {
    let obj = try JSONSerialization.jsonObject(with: data)
    if let dict = obj as? [String: Any] { return dict }
    if let text = obj as? String, let d = text.data(using: .utf8),
       let dict = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
      return dict
    }
    throw ALSourceError.invalidResponse("网易评论响应异常")
  }
}
