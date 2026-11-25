import Foundation

/// QQ音乐（tx）评论解析层
///
/// 参照（只读）：`extensions/online-metadata/src/onlineResource/tx/musicComment.ts`
/// 对外 API：`ALCommentTx.comment(music:type:page:limit:)`
///   - "new"：POST 表单 `fcg_global_comment_h5.fcg`（getComment）
///   - "hot"：POST JSON  `musicu.fcg` / music.globalComment.CommentRead.GetHotCommentList
///   - "reply"：扩展中 getReplyComment 尚未启用，按 unsupported(.tx) 处理
enum ALCommentTx {

  // MARK: - 入口

  static func comment(music: MusicInfo, type: String, page: Int, limit: Int = 20) async throws -> ALMusicCommentResult {
    // iMusic 已在 tx 搜索结果 extra 中透传 songId（见 AnyListenTx.swift），无需再次 getMusicInfo
    let songId = Int(music.extra?["songId"] ?? music.songmid) ?? 0
    switch type {
    case "new":
      return try await getComment(songId: songId, page: page, limit: limit)
    case "hot":
      return try await getHotComment(songId: songId, page: page, limit: limit)
    case "reply":
      // 对应 TS 中注释掉的 getReplyComment：`reply comment is not supported yet`
      throw ALSourceError.unsupported(.tx)
    default:
      throw ALSourceError.invalidResponse("QQ音乐评论类型无效：\(type)")
    }
  }

  // MARK: - new 评论

  private static let chromeUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  private static func getComment(songId: Int, page: Int, limit: Int) async throws -> ALMusicCommentResult {
    // musicComment.ts:199-213 的原始表单键（cmd=8 / topid / pagenum=page-1 / pagesize=limit）
    let form: [(String, String)] = [
      ("uin", "0"),
      ("format", "json"),
      ("cid", "205360772"),
      ("reqtype", "2"),
      ("biztype", "1"),
      ("topid", "\(songId)"),
      ("cmd", "8"),
      ("needmusiccrit", "1"),
      ("pagenum", "\(page - 1)"),
      ("pagesize", "\(limit)"),
    ]
    let headers = [
      "User-Agent": chromeUA,
      "Referer": "https://y.qq.com/",
      "Origin": "https://y.qq.com",
    ]
    let json = try await ALHttp.postForm(
      "https://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg", form: form, headers: headers)
    guard let body = json as? [String: Any],
          ALHttp.int(body["code"]) == 0,
          let comment = body["comment"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("QQ音乐评论失败")
    }
    let total = ALHttp.int(comment["commenttotal"]) ?? 0
    let list = filterNewComment(ALHttp.arr(comment["commentlist"]) ?? [])
    return ALMusicCommentResult(list: list, total: total, limit: limit, page: page)
  }

  // MARK: - hot 评论

  private static func getHotComment(songId: Int, page: Int, limit: Int) async throws -> ALMusicCommentResult {
    // musicComment.ts:241-267
    let comm: [String: Any] = [
      "cv": 4747474,
      "ct": 24,
      "format": "json",
      "inCharset": "utf-8",
      "outCharset": "utf-8",
      "notice": 0,
      "platform": "yqq.json",
      "needNewCode": 1,
      "uin": 0,
    ]
    let param: [String: Any] = [
      "BizType": 1,
      "BizId": "\(songId)",
      "LastCommentSeqNo": "",
      "PageSize": limit,
      "PageNum": page - 1,
      "HotType": 1,
      "WithAirborne": 0,
      "PicEnable": 1,
    ]
    let reqBody: [String: Any] = [
      "module": "music.globalComment.CommentRead",
      "method": "GetHotCommentList",
      "param": param,
    ]
    let payload: [String: Any] = ["comm": comm, "req": reqBody]
    let json = try await ALHttp.postJSON(
      "https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload,
      headers: ["Referer": "https://y.qq.com/", "Origin": "https://y.qq.com"])
    guard let body = json as? [String: Any],
          ALHttp.int(body["code"]) == 0,
          let req = body["req"] as? [String: Any],
          ALHttp.int(req["code"]) == 0,
          let data = req["data"] as? [String: Any],
          let listData = data["CommentList"] as? [String: Any] else {
      throw ALSourceError.invalidResponse("QQ音乐热评失败")
    }
    let total = ALHttp.int(listData["Total"]) ?? 0
    let list = filterHotComment(ALHttp.arr(listData["Comments"]) ?? [])
    return ALMusicCommentResult(list: list, total: total, limit: limit, page: page)
  }

  // MARK: - 表情（musicComment.ts:8-76 / 100-111）

  /// TS 键为 `[em]e400846[/em]` 这类代码，值为 emoji
  private static let emojis: [String: String] = [
    "e400846": "😘", "e400874": "😴", "e400825": "😃", "e400847": "😙",
    "e400835": "😍", "e400873": "😳", "e400836": "😎", "e400867": "😭",
    "e400832": "😊", "e400837": "😏", "e400875": "😫", "e400831": "😉",
    "e400855": "😡", "e400823": "😄", "e400862": "😨", "e400844": "😖",
    "e400841": "😓", "e400830": "😈", "e400828": "😆", "e400833": "😋",
    "e400822": "😀", "e400843": "😕", "e400829": "😇", "e400824": "😂",
    "e400834": "😌", "e400877": "😷", "e400132": "🍉", "e400181": "🍺",
    "e401067": "☕️", "e400186": "🥧", "e400343": "🐷", "e400116": "🌹",
    "e400126": "🍃", "e400613": "💋", "e401236": "❤️", "e400622": "💔",
    "e400637": "💣", "e400643": "💩", "e400773": "🔪", "e400102": "🌛",
    "e401328": "🌞", "e400420": "👏", "e400914": "🙌", "e400408": "👍",
    "e400414": "👎", "e401121": "✋", "e400396": "👋", "e400384": "👉",
    "e401115": "✊", "e400402": "👌", "e400905": "🙈", "e400906": "🙉",
    "e400907": "🙊", "e400562": "👻", "e400932": "🙏", "e400644": "💪",
    "e400611": "💉", "e400185": "🎁", "e400655": "💰", "e400325": "🐥",
    "e400612": "💊", "e400198": "🎉", "e401685": "⚡️", "e400631": "💝",
    "e400768": "🔥", "e400432": "👑",
  ]

  private static func replaceEmoji(_ msg: String) -> String {
    guard let re = try? NSRegularExpression(pattern: "\\[em\\](e\\d+)\\[/em\\]") else { return msg }
    let ns = msg as NSString
    let matches = re.matches(in: msg, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return msg }
    var out = msg
    var seen = Set<String>()
    for m in matches {
      guard let fullRange = Range(m.range(at: 0), in: msg),
            let codeRange = Range(m.range(at: 1), in: msg) else { continue }
      let code = String(msg[codeRange])
      guard seen.insert(code).inserted else { continue }
      out = out.replacingOccurrences(of: String(msg[fullRange]), with: emojis[code] ?? "")
    }
    return out
  }

  /// TS: replaceEmoji(text).replace(/\\n/g, '\n')；额外经 decodeName 还原 HTML 实体
  private static func plainText(_ raw: String?) -> String {
    guard let raw else { return "" }
    return ALFormat.decodeName(replaceEmoji(raw)).replacingOccurrences(of: "\\n", with: "\n")
  }

  /// TS 的 `x ?? undefined`（NSNull / 缺失 → nil，空串保留）
  private static func strOrNil(_ v: Any?) -> String? {
    guard let v, !(v is NSNull) else { return nil }
    return ALHttp.str(v)
  }

  /// TS formatTime：字符串长度 < 10 → null，否则秒时间戳转毫秒
  private static func formatTime(_ v: Any?) -> Int? {
    let s = ALHttp.str(v)
    guard s.count >= 10, let ms = Int(s + "000") else { return nil }
    return ms
  }

  // MARK: - 格式化（musicComment.ts:113-186）

  private static func formatReplyByNew(rootId: String, commentId: String,
                                        time: Int?, c: [String: Any]) -> ALMusicCommentItem {
    let subId = ALHttp.str(c["subcommentid"])
    let nick = strOrNil(c["replynick"])
    return ALMusicCommentItem(
      id: "sub_\(rootId)_\(subId)",
      userId: strOrNil(c["encrypt_replyuin"]),
      userName: nick.map { String($0.dropFirst()) } ?? "",
      text: plainText(strOrNil(c["subcommentcontent"])),
      time: subId == commentId ? time : nil,
      avatar: strOrNil(c["avatarurl"]),
      likedCount: ALHttp.int(c["praisenum"]))
  }

  private static func filterNewComment(_ rawList: [[String: Any]]) -> [ALMusicCommentItem] {
    rawList.map { item in
      let time = formatTime(item["time"])
      var middle = ALHttp.arr(item["middlecommentcontent"]) ?? []
      if !middle.isEmpty {
        // 反转前把主评头像 / 点赞数补到第一条子评（TS:135-140）
        if let avatar = strOrNil(item["avatarurl"]) { middle[0]["avatarurl"] = avatar }
        else { middle[0].removeValue(forKey: "avatarurl") }
        if let praise = ALHttp.int(item["praisenum"]) { middle[0]["praisenum"] = praise }
        else { middle[0].removeValue(forKey: "praisenum") }
        middle.reverse()
      }
      let rootId = ALHttp.str(item["rootcommentid"])
      let commentId = ALHttp.str(item["commentid"])
      let nick = strOrNil(item["rootcommentnick"])
      let text = strOrNil(item["rootcommentcontent"]).map { plainText($0) } ?? ""
      return ALMusicCommentItem(
        id: "\(rootId)_\(commentId)",
        userId: strOrNil(item["encrypt_rootcommentuin"]),
        userName: nick.map { String($0.dropFirst()) } ?? "",
        text: text,
        time: rootId == commentId ? time : nil,
        avatar: strOrNil(item["avatarurl"]),
        likedCount: ALHttp.int(item["praisenum"]),
        reply: middle.map { formatReplyByNew(rootId: rootId, commentId: commentId, time: time, c: $0) })
    }
  }

  private static func formatReplyByHot(_ c: [String: Any]) -> ALMusicCommentItem {
    let time = c["PubTime"].flatMap { formatTime($0) }
    let pic = strOrNil(c["Pic"])
    return ALMusicCommentItem(
      id: "sub_\(ALHttp.str(c["SeqNo"]))_\(ALHttp.str(c["CmId"]))",
      userId: strOrNil(c["EncryptUin"]),
      userName: strOrNil(c["Nick"]) ?? "",
      text: plainText(strOrNil(c["Content"])),
      time: time,
      images: pic.map { [$0] } ?? [],
      avatar: strOrNil(c["Avatar"]),
      likedCount: ALHttp.int(c["PraiseNum"]))
  }

  private static func filterHotComment(_ rawList: [[String: Any]]) -> [ALMusicCommentItem] {
    rawList.map { item in
      let time = item["PubTime"].flatMap { formatTime($0) }
      let pic = strOrNil(item["Pic"])
      let subs = ALHttp.arr(item["SubComments"]) ?? []
      return ALMusicCommentItem(
        id: "\(ALHttp.str(item["SeqNo"]))_\(ALHttp.str(item["CmId"]))",
        userId: strOrNil(item["EncryptUin"]),
        userName: strOrNil(item["Nick"]) ?? "",
        text: strOrNil(item["Content"]).map { plainText($0) } ?? "",
        time: time,
        images: pic.map { [$0] } ?? [],
        location: strOrNil(item["Location"]) ?? "",
        avatar: strOrNil(item["Avatar"]),
        likedCount: ALHttp.int(item["PraiseNum"]),
        reply: subs.map { formatReplyByHot($0) })
    }
  }
}
