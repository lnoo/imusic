import Foundation

// MARK: - 额外搜索能力：热搜词 + 搜索提示（kw / kg / tx / wy）
//
// 严格移植自只读 submodule（仅参考，不做任何改动）：
//   extensions/online-metadata/src/onlineResource/kw/hotSearch.ts
//   extensions/online-metadata/src/onlineResource/kw/tipSearch.ts
//   extensions/online-metadata/src/onlineResource/kg/hotSearch.ts
//   extensions/online-metadata/src/onlineResource/kg/tipSearch.ts
//   extensions/online-metadata/src/onlineResource/tx/hotSearch.ts
//   extensions/online-metadata/src/onlineResource/tx/tipSearch.ts
//   extensions/online-metadata/src/onlineResource/wy/hotSearch.ts
//     （wy 热搜沿用 AnyListenWy.hotSearch()，本层仅转发，不重复实现）
//   extensions/online-metadata/src/onlineResource/wy/tipSearch.ts
//
// 端点、请求头、参数、状态码/业务码校验与字段映射逐条对齐上述源码。
enum ALExtraSearch {
  /// JS `encodeURIComponent` 等价字符集（保留 A-Za-z0-9 与 -_.!~*'()）
  private static func encoded(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
    ) ?? ""
  }

  // MARK: - 分发

  /// kw/kg/tx 按扩展原生实现；wy 转发已有 AnyListenWy.hotSearch()；其余源不支持。
  static func hotSearch(source: MusicSource) async throws -> [String] {
    switch source {
    case .kw: return try await kwHotSearch()
    case .kg: return try await kgHotSearch()
    case .tx: return try await txHotSearch()
    case .wy: return try await AnyListenWy.hotSearch()
    case .mg, .local,
         .gdNetease, .gdKuwo, .gdTencent, .gdJoox, .gdTidal, .gdQobuz,
         .gdBilibili, .gdApple, .gdYtmusic, .gdSpotify:
      throw ALSourceError.unsupported(source)
    }
  }

  static func tipSearch(source: MusicSource, keyword: String) async throws -> [String] {
    switch source {
    case .kw: return try await kwTipSearch(keyword)
    case .kg: return try await kgTipSearch(keyword)
    case .tx: return try await txTipSearch(keyword)
    case .wy: return try await wyTipSearch(keyword)
    case .mg, .local,
         .gdNetease, .gdKuwo, .gdTencent, .gdJoox, .gdTidal, .gdQobuz,
         .gdBilibili, .gdApple, .gdYtmusic, .gdSpotify:
      throw ALSourceError.unsupported(source)
    }
  }

  // MARK: - 酷我 kw

  private static func kwHotSearch() async throws -> [String] {
    let url = "http://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo&newver=2&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1&notrace=0&uid=0&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1"
    let json = try await ALHttp.getJSON(
      url,
      headers: ["User-Agent": "Dalvik/2.1.0 (Linux; U; Android 9;)"],
      requireOK: true
    )
    guard let root = ALHttp.dict(json), ALHttp.str(root["status"]) == "ok" else {
      throw ALSourceError.invalidResponse("kw hotSearch failed")
    }
    return (ALHttp.arr(root["tagvalue"]) ?? []).map { ALHttp.str($0["key"]) }
  }

  private static func kwTipSearch(_ keyword: String) async throws -> [String] {
    let url = "https://tips.kuwo.cn/t.s?corp=kuwo&newver=3&p2p=1&notrace=0&c=mbox&w=\(encoded(keyword))&encoding=utf8&rformat=json"
    let json = try await ALHttp.getJSON(
      url,
      headers: ["Referer": "http://www.kuwo.cn/"],
      requireOK: true
    )
    guard let root = ALHttp.dict(json), root["WORDITEMS"] != nil else {
      throw ALSourceError.invalidResponse("kw tipSearch failed")
    }
    return (ALHttp.arr(root["WORDITEMS"]) ?? []).map { ALHttp.str($0["RELWORD"]) }
  }

  // MARK: - 酷狗 kg

  private static func kgHotSearch() async throws -> [String] {
    let url = "http://gateway.kugou.com/api/v3/search/hot_tab?signature=ee44edb9d7155821412d220bcaf509dd&appid=1005&clientver=10026&plat=0"
    let headers = [
      "dfid": "1ssiv93oVqMp27cirf2CvoF1",
      "mid": "156798703528610303473757548878786007104",
      "clienttime": "1584257267",
      "x-router": "msearch.kugou.com",
      "user-agent": "Android9-AndroidPhone-10020-130-0-searchrecommendprotocol-wifi",
      "kg-rc": "1",
    ]
    let json = try await ALHttp.getJSON(url, headers: headers, requireOK: true)
    guard let root = ALHttp.dict(json), ALHttp.int(root["errcode"]) == 0 else {
      throw ALSourceError.invalidResponse("kg hotSearch failed")
    }
    let list = ALHttp.arr(ALHttp.dict(root["data"])?["list"]) ?? []
    var result: [String] = []
    for item in list {
      for keyword in ALHttp.arr(item["keywords"]) ?? [] {
        let word = ALHttp.str(keyword["keyword"])
        if !word.isEmpty { result.append(ALFormat.decodeName(word)) }
      }
    }
    return result
  }

  private static func kgTipSearch(_ keyword: String) async throws -> [String] {
    let url = "https://searchtip.kugou.com/getSearchTip?MusicTipCount=10&keyword=\(encoded(keyword))"
    let json = try await ALHttp.getJSON(
      url,
      headers: ["Referer": "https://www.kugou.com/"],
      requireOK: true
    )
    guard let root = ALHttp.dict(json), ALHttp.int(root["error_code"]) == 0,
          let data = ALHttp.arr(root["data"]), let first = data.first else {
      throw ALSourceError.invalidResponse("kg tipSearch failed")
    }
    return (ALHttp.arr(first["RecordDatas"]) ?? [])
      .map { ALHttp.str($0["HintInfo"]) }
      .filter { !$0.isEmpty }
  }

  // MARK: - 腾讯 tx

  private static func txHotSearch() async throws -> [String] {
    let comm: [String: Any] = [
      "ct": "19",
      "cv": "1803",
      "guid": "0",
      "patch": "118",
      "psrf_access_token_expiresAt": 0,
      "psrf_qqaccess_token": "",
      "psrf_qqopenid": "",
      "psrf_qqunionid": "",
      "tmeAppID": "qqmusic",
      "tmeLoginType": 0,
      "uin": "0",
      "wid": "0",
    ]
    let hotkey: [String: Any] = [
      "method": "GetHotkeyForQQMusicPC",
      "module": "tencent_musicsoso_hotkey.HotkeyService",
      "param": ["search_id": "", "uin": 0],
    ]
    let payload: [String: Any] = ["comm": comm, "hotkey": hotkey]
    let json = try await postJSON(
      "https://u.y.qq.com/cgi-bin/musicu.fcg",
      json: payload,
      headers: ["Referer": "https://y.qq.com/portal/player.html"]
    )
    guard let root = ALHttp.dict(json), ALHttp.int(root["code"]) == 0 else {
      throw ALSourceError.invalidResponse("tx hotSearch failed")
    }
    let data = ALHttp.dict(ALHttp.dict(root["hotkey"])?["data"])
    return (ALHttp.arr(data?["vec_hotkey"]) ?? [])
      .map { ALHttp.str($0["query"]) }
      .filter { !$0.isEmpty }
  }

  private static func txTipSearch(_ keyword: String) async throws -> [String] {
    let url = "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?is_xml=0&format=json&key=\(encoded(keyword))&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq&needNewCode=0"
    let json = try await ALHttp.getJSON(
      url,
      headers: ["Referer": "https://y.qq.com/portal/player.html"],
      requireOK: true
    )
    guard let root = ALHttp.dict(json), ALHttp.int(root["code"]) == 0 else {
      throw ALSourceError.invalidResponse("tx tipSearch failed")
    }
    let song = ALHttp.dict(ALHttp.dict(root["data"])?["song"])
    return (ALHttp.arr(song?["itemlist"]) ?? []).map { item in
      let name = ALHttp.str(item["name"])
      let singer = ALHttp.str(item["singer"])
      return "\(name) \(singer)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  // MARK: - 网易云 wy（tipSearch；hotSearch 走 AnyListenWy）

  private static func wyTipSearch(_ keyword: String) async throws -> [String] {
    let url = "https://music.163.com/weapi/search/suggest/web"
    let crypto = ALCrypto.weapiParams(["s": keyword], url: url)
    let form = [
      "params": encoded(crypto.params),
      "encSecKey": encoded(crypto.encSecKey),
    ]
    let headers = [
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
      "Referer": "https://music.163.com/",
      "Origin": "https://music.163.com",
    ]
    let json = try await postForm(url, form: form, headers: headers)
    guard let root = ALHttp.dict(json), ALHttp.int(root["code"]) == 200 else {
      throw ALSourceError.invalidResponse("wy tipSearch failed")
    }
    let result = ALHttp.dict(root["result"])
    return (ALHttp.arr(result?["songs"]) ?? []).map { song in
      let name = ALHttp.str(song["name"])
      let singer = ALFormat.singerName(song["artists"])
      return "\(name) \(singer)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  // MARK: - 私有 POST 助手（自带 HTTP 200 校验，对齐 hostApi request 的 statusCode 检查）

  private static func postJSON(_ urlString: String, json: [String: Any],
                               headers: [String: String]) async throws -> Any {
    guard let url = URL(string: urlString) else {
      throw ALSourceError.invalidResponse("invalid URL: \(urlString)")
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
    req.httpBody = try JSONSerialization.data(withJSONObject: json)
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw ALSourceError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
    }
    return try JSONSerialization.jsonObject(with: data)
  }

  private static func postForm(_ urlString: String, form: [String: String],
                               headers: [String: String]) async throws -> Any {
    guard let url = URL(string: urlString) else {
      throw ALSourceError.invalidResponse("invalid URL: \(urlString)")
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
    req.httpBody = form.map { "\($0.key)=\(encoded($0.value))" }
      .joined(separator: "&")
      .data(using: .utf8)
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw ALSourceError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
    }
    return try JSONSerialization.jsonObject(with: data)
  }
}
