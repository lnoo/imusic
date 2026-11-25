import Foundation

// MARK: - GD音乐台签名服务器通道（移植自只读 submodule extensions/gdstudio）
//
// 参考（只读，不改动 submodule）：
//   extensions/gdstudio/src/index.ts:17-31    ORG_SOURCES / isOrgSource / toGdSource
//   extensions/gdstudio/src/index.ts:544-621  apiCallOrg：取签名 → 立即原样发出成品请求
//   extensions/gdstudio/src/signServerSettings.ts 配置键 signServerUrl / signKey / useOrgSource
//
// 配置直接落在 UserDefaults（纯键、无迁移/无兼容层）：
//   signServerUrl / signKey / useOrgSource / preloadQualityOnSearch（默认 true）
// 签名时效仅 5~15 秒，因此每次调用都重新向 /sign 取签名，拿到后立刻按成品请求原样发出。

enum ALGdSign {
  private enum Key {
    static let signServerUrl = "signServerUrl"
    static let signKey = "signKey"
    static let useOrgSource = "useOrgSource"
    static let preloadQualityOnSearch = "preloadQualityOnSearch"
  }

  /// 与 gdstudio ORG_SOURCES（index.ts:17）一致：这些源必须走签名服务器。
  private static let orgSources: Set<String> = [
    "tencent", "tidal", "qobuz", "apple", "ytmusic", "spotify",
  ]

  // MARK: - 配置（UserDefaults 直通，无迁移）

  static var signServerUrl: String {
    get { UserDefaults.standard.string(forKey: Key.signServerUrl) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: Key.signServerUrl) }
  }

  static var signKey: String {
    get { UserDefaults.standard.string(forKey: Key.signKey) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: Key.signKey) }
  }

  static var useOrgSource: Bool {
    get { UserDefaults.standard.bool(forKey: Key.useOrgSource) }
    set { UserDefaults.standard.set(newValue, forKey: Key.useOrgSource) }
  }

  static var preloadQualityOnSearch: Bool {
    get { UserDefaults.standard.object(forKey: Key.preloadQualityOnSearch) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: Key.preloadQualityOnSearch) }
  }

  /// 签名服务器地址与密钥是否都已填写（去除首尾空白后判断）。
  static var hasConfig: Bool {
    !signServerUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !signKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// 用户可见的配置检查：缺配置时直接抛出可展示的错误。
  static func requireConfig() throws {
    guard hasConfig else {
      throw ALSourceError.invalidResponse(
        "签名服务器未配置或请求失败：请先在「音源设置 → GD音乐台签名服务」填写服务地址与密钥"
      )
    }
  }

  // MARK: - 源判定

  /// `useOrgSource` 开启时所有源都走签名服务器；否则仅 org 系列源。
  /// 采用 toGdSource 语义：先剥离 `gd-` / `gd_` 前缀再匹配（identity.ts:20-23）。
  static func isOrgSource(_ source: String) -> Bool {
    if useOrgSource { return true }
    let value = String(source)
    let normalized = value.hasPrefix("gd-") || value.hasPrefix("gd_")
      ? String(value.dropFirst(3)) : value
    return orgSources.contains(normalized)
  }

  // MARK: - 签名调用

  /// 向签名服务器取成品请求，并立即按原样发出。
  ///
  /// - Parameters:
  ///   - types: 业务操作名（对应签名服务器 `op`，如 search / url / lyric / pic）。
  ///   - source: GD 音源名（如 tencent / gd-apple）。
  ///   - extra: 其余业务参数；`pages` 按 gdstudio 约定映射为签名服务器的 `page`。
  /// - Returns: 上游 JSON（由调用方按各动作自行解析）。
  static func call(types: String, source: String, extra: [String: String] = [:]) async throws -> Any {
    try requireConfig()

    let base = signServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    var params: [(String, String)] = [("op", types), ("source", source)]
    for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
      if key == "types" || key == "source" { continue }
      params.append((key == "pages" ? "page" : key, value))
    }
    let query = params.map { "\(encodeURIComponent($0.0))=\(encodeURIComponent($0.1))" }
      .joined(separator: "&")
    guard let signURL = URL(string: "\(base)/sign?\(query)") else {
      throw ALSourceError.invalidResponse("签名服务器未配置或请求失败：服务地址无效")
    }

    let signHeaders = [
      "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "Authorization": "Bearer \(signKey.trimmingCharacters(in: .whitespacesAndNewlines))",
    ]
    let signData = try await requestRaw(signURL, method: "GET", headers: signHeaders,
                                        body: nil, timeout: 8)
    let signJSON = try JSONSerialization.jsonObject(with: signData)
    guard let root = ALHttp.dict(signJSON),
          (root["ok"] as? NSNumber)?.boolValue == true,
          let req = ALHttp.dict(root["req"]),
          let reqURLString = req["url"] as? String, !reqURLString.isEmpty,
          let reqURL = URL(string: reqURLString) else {
      throw ALSourceError.invalidResponse("签名服务器未配置或请求失败")
    }

    // 成品请求的 method/headers/body 原样透传；签名秒级过期，不做任何缓存或延迟。
    var headers: [String: String] = [:]
    if let rawHeaders = ALHttp.dict(req["headers"]) {
      for (k, v) in rawHeaders { headers[k] = ALHttp.str(v) }
    }
    let bodyValue = req["body"]
    let body: String? = {
      guard let bodyValue, !(bodyValue is NSNull) else { return nil }
      return bodyValue as? String ?? ALHttp.str(bodyValue)
    }()
    let method = (req["method"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "POST"

    let upstream = try await requestRaw(
      reqURL, method: method, headers: headers, body: body, timeout: 15
    )
    return try JSONSerialization.jsonObject(with: upstream)
  }

  // MARK: - 内部工具

  /// JS `encodeURIComponent` 等价字符集（保留 A-Za-z0-9 与 -_.!~*'()）。
  private static func encodeURIComponent(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
    ) ?? ""
  }

  /// 原始请求：按给定的 method / headers / body 精确发出，校验 HTTP 200 后返回字节。
  private static func requestRaw(_ url: URL, method: String, headers: [String: String],
                                 body: String?, timeout: TimeInterval) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    if let body { request.httpBody = Data(body.utf8) }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ALSourceError.invalidResponse("签名服务器未配置或请求失败：非 HTTP 响应")
    }
    guard http.statusCode == 200 else {
      throw ALSourceError.invalidResponse("签名服务器未配置或请求失败：HTTP \(http.statusCode)")
    }
    return data
  }
}
