import Foundation

// MARK: - 酷我评论（ALCommentKw）
//
// 严格移植 extensions/online-metadata/src/onlineResource/kw/musicComment.ts（只读参考实现）：
//   :6-8    UA `Dalvik/2.1.0 (Linux; U; Android 9;)`
//   :10-14  songId 取 meta.musicId 优先，回退 music.id（Swift 侧对应 extra["songId"] → songmid）
//   :16-44  formatReplyComment：child_comments 元素的 reply 为单个对象，映射成 1 条回复列表
//   :46-62  filterComment：id/msg/time*1000/u_name/u_pic/u_id/like_num/mpic + child_comments
//   :64-89  getComment：type=get_comment，默认 limit=20，total=comments_counts
//   :91-116 getHotComment：type=get_rec_comment，默认 limit=100，total=hot_comments_counts
//   :118-139 musicComment：reply 类型显式抛错
//
// 说明：URL/字段校验与扩展一致（字符串 code=="200"）；扩展用 decodeURIComponent 解码 mpic，
//       Swift 侧用 String.removingPercentEncoding；实体解码统一走 ALFormat.decodeName。

enum ALCommentKw {
  private static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 9;)"
  private static let endpoint = "http://ncomment.kuwo.cn/com.s"

  /// 酷我歌曲评论（对齐扩展 musicComment 的 new/hot/reply 三态分发）
  ///
  /// - type: `"new"` / `"hot"` / `"reply"`（reply 扩展明确不支持 → ALSourceError.unsupported(.kw)）
  /// - limit: 扩展默认 new=20 / hot=100；分发层默认传入 20，故 hot 遇到默认值时按扩展默认 100 处理
  static func comment(music: MusicInfo, type: String, page: Int, limit: Int = 20) async throws -> ALMusicCommentResult {
    let songId = music.extra?["songId"].flatMap { $0.isEmpty ? nil : $0 } ?? music.songmid

    let effectiveLimit: Int
    let commentType: String
    switch type {
    case "new":
      // musicComment.ts:66-67 getComment(page = 1, limit = 20)
      effectiveLimit = limit
      commentType = "get_comment"
    case "hot":
      // musicComment.ts:93-94 getHotComment(page = 1, limit = 100)
      effectiveLimit = limit == 20 ? 100 : limit
      commentType = "get_rec_comment"
    case "reply":
      // musicComment.ts:131-133 reply comment is not supported yet
      throw ALSourceError.unsupported(.kw)
    default:
      throw ALSourceError.invalidResponse("酷我评论类型无效：\(type)")
    }

    let start = effectiveLimit * (page - 1)
    let url = "\(Self.endpoint)?f=web&type=\(commentType)&aapiver=1"
      + "&prod=kwplayer_ar_10.5.2.0&digest=15&sid=\(songId)"
      + "&start=\(start)&msgflag=1&count=\(effectiveLimit)&newver=3&uid=0"

    // requireOK：扩展 :81 / :108 的 statusCode !== 200 校验
    let json = try await ALHttp.getJSON(url, headers: ["User-Agent": Self.userAgent], requireOK: true)
    guard let body = json as? [String: Any], ALHttp.str(body["code"]) == "200" else {
      throw ALSourceError.invalidResponse("酷我评论失败")
    }

    let rawList = type == "hot" ? body["hot_comments"] : body["comments"]
    let totalKey = type == "hot" ? "hot_comments_counts" : "comments_counts"
    return ALMusicCommentResult(
      list: Self.filterComment(ALHttp.arr(rawList) ?? []),
      total: ALHttp.int(body[totalKey]) ?? 0,
      limit: effectiveLimit,
      page: page
    )
  }

  // MARK: 条目映射（musicComment.ts :16-62）

  /// filterComment：body.comments / body.hot_comments → 评论列表
  private static func filterComment(_ rawList: [[String: Any]]) -> [ALMusicCommentItem] {
    rawList.map { item in
      let children = ALHttp.arr(item["child_comments"]) ?? []
      return makeItem(item, replies: children.map { makeReply($0) })
    }
  }

  /// formatReplyComment：child_comments 的 reply 单对象 → 长度至多 1 的回复列表
  private static func makeReply(_ item: [String: Any]) -> ALMusicCommentItem {
    let nested = (item["reply"] as? [String: Any]).map { [makeItem($0, replies: [])] } ?? []
    return makeItem(item, replies: nested)
  }

  /// 公共字段映射：id / msg / time*1000 / u_name / u_pic / u_id / like_num / mpic
  private static func makeItem(_ raw: [String: Any], replies: [ALMusicCommentItem]) -> ALMusicCommentItem {
    // decodeURIComponent(reply.mpic) —— 解码失败（非法 % 序列）时保留原串
    let mpic = ALHttp.str(raw["mpic"])
    let images: [String] = mpic.isEmpty ? [] : [mpic.removingPercentEncoding ?? mpic]
    let avatar = ALHttp.str(raw["u_pic"])
    let userId = ALHttp.str(raw["u_id"])

    return ALMusicCommentItem(
      id: ALHttp.str(raw["id"]),
      userId: userId.isEmpty ? nil : userId,
      userName: ALFormat.decodeName(ALHttp.str(raw["u_name"])),
      text: ALFormat.decodeName(ALHttp.str(raw["msg"])),
      time: ALHttp.int(raw["time"]).map { $0 * 1000 },
      images: images,
      location: nil,
      avatar: avatar.isEmpty ? nil : avatar,
      likedCount: ALHttp.int(raw["like_num"]),
      skipPage: nil,
      replyTotal: nil,
      reply: replies,
      replySkipPage: nil
    )
  }
}
