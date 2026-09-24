import Foundation
import CryptoKit
import CommonCrypto

// MARK: - 签名与格式化小工具
// 对标：renderer/utils/index.ts(sizeFormate/formatPlayTime/decodeName)
//      tx/utils/crypto.js(zzcSign) / wy/utils/crypto.js(eapi) / mg/musicSearch.js(createSignature)

enum iMusicSign {
  static func md5(_ s: String) -> String {
    Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func sha1(_ s: String) -> String {
    Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// 字节数 -> "3.56M"（对标 sizeFormate）
  static func size(_ bytes: Any?) -> String? {
    let b: Double
    if let n = bytes as? Double { b = n }
    else if let n = bytes as? Int { b = Double(n) }
    else if let s = bytes as? String, let n = Double(s) { b = n }
    else if let n = bytes as? NSNumber { b = n.doubleValue }
    else { return nil }
    guard b > 0 else { return nil }
    if b < 1024 { return "\(Int(b))B" }
    if b < 1024 * 1024 { return String(format: "%.2fK", b / 1024) }
    if b < 1024 * 1024 * 1024 { return String(format: "%.2fM", b / 1024 / 1024) }
    return String(format: "%.2fG", b / 1024 / 1024 / 1024)
  }

  /// HTML 反转义（对标 decodeName）
  static func decode(_ s: String) -> String {
    s.replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&", with: "&")
      .replacingOccurrences(of: "<", with: "<")
      .replacingOccurrences(of: ">", with: ">")
      .replacingOccurrences(of: "", with: "\"")
      .replacingOccurrences(of: "&#039;", with: "'")
  }

  static func mmss(_ sec: Int) -> String {
    guard sec > 0 else { return "00:00" }
    return String(format: "%02d:%02d", sec / 60, sec % 60)
  }

  static func singerNames(_ arr: [[String: Any]]) -> String {
    arr.compactMap { $0["name"] as? String }.joined(separator: "、")
  }

  // MARK: - Deterministic JSON for tx (matches Node JSON.stringify insertion order)
  private static func txJSONString(_ obj: [String: Any], keyOrder: [String]) -> String {
    var parts: [String] = []
    for k in keyOrder {
      if let v = obj[k] {
        parts.append("\"\(k)\":\(jsonValue(v))")
      }
    }
    return "{" + parts.joined(separator: ",") + "}"
  }

  private static func jsonValue(_ v: Any) -> String {
    if let s = v as? String { return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\"" }
    if let n = v as? NSNumber {
      if n === kCFBooleanTrue || n === kCFBooleanFalse { return n.boolValue ? "true" : "false" }
      return n.stringValue
    }
    if let i = v as? Int { return "\(i)" }
    if let d = v as? Double { return "\(d)" }
    if let arr = v as? [Any] { return "[" + arr.map(jsonValue).joined(separator: ",") + "]" }
    if let dict = v as? [String: Any] {
      let keys = dict.keys.sorted()
      return "{" + keys.map { "\"\($0)\":\(jsonValue(dict[$0]!))" }.joined(separator: ",") + "}"
    }
    return "null"
  }

  // Expose for MultiSource
  static func txSignPayload(comm: [String: Any], searchSvc: [String: Any], param: [String: Any]) -> String {
    let searchSvcStr = txJSONString(searchSvc, keyOrder: searchKeyOrder)
    let commStr = txJSONString(comm, keyOrder: commKeyOrder)
    return "{\"comm\":" + commStr + ",\"music.search.SearchCgiService\":" + searchSvcStr + "}"
  }

  static let commKeyOrder = ["_channelid", "_os_version", "ct", "cv", "guid", "patch", "psrf_access_token_expiresAt", "psrf_qqaccess_token", "psrf_qqopenid", "psrf_qqunionid", "tmeAppID", "tmeLoginType", "uin", "wid"]
  static let searchKeyOrder = ["module", "method", "param"]
  static let paramKeyOrder = ["grp", "num_per_page", "page_num", "query", "remoteplace", "search_type", "searchid"]

  // MARK: - tx zzcSign（对标 tx/utils/crypto.js，纯 SHA1+查表，无需网络）
  static func zzcSign(_ text: String) -> String {
    let hash = sha1(text)
    let chars = Array(hash)
    let p1idx = [23, 14, 6, 36, 16, 40, 7, 19]
    let p2idx = [16, 1, 32, 12, 19, 27, 8, 5]
    let scramble = [89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179]
    let part1 = p1idx.map { $0 < chars.count ? String(chars[$0]) : "" }.joined()
    let part2 = p2idx.map { $0 < chars.count ? String(chars[$0]) : "" }.joined()
    var bytes: [UInt8] = []
    for (i, v) in scramble.enumerated() {
      let hex = String(chars[(i * 2)..<(i * 2 + 2)])
      bytes.append(UInt8(v ^ Int(UInt8(hex, radix: 16) ?? 0)))
    }
    let b64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "[\\/+=]", with: "", options: .regularExpression)
    return "zzc\(part1)\(b64)\(part2)".lowercased()
  }

  // MARK: - wy eapi（对标 wy/utils/crypto.js eapi；搜索/歌词只用 eapi，无需 RSA）
  static func wyEapiParams(url: String, object: [String: Any]) throws -> String {
    let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? "{}"
    let message = "nobody\(url)use\(text)md5forencrypt"
    let digest = md5(message)
    let data = "\(url)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
    let enc = try aesECBEncrypt([UInt8](Data(data.utf8)), key: [UInt8](Data("e82ckenh8dichen8".utf8)))
    return enc.map { String(format: "%02x", $0) }.joined().uppercased()
  }

  /// AES-128-ECB/PKCS7（非隔离，可在任意线程调用）
  static func aesECBEncrypt(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
    var k = key
    if k.count < kCCKeySizeAES128 { k += [UInt8](repeating: 0, count: kCCKeySizeAES128 - k.count) }
    let cap = data.count + kCCBlockSizeAES128
    let out = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
    defer { out.deallocate() }
    var len: size_t = 0
    let st = k.withUnsafeBytes { kp in data.withUnsafeBytes { dp in
      CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
              kp.baseAddress, kCCKeySizeAES128, nil, dp.baseAddress, data.count, out, cap, &len)
    } }
    guard st == kCCSuccess else { throw NSError(domain: "LX", code: -1, userInfo: [NSLocalizedDescriptionKey: "AES failed"]) }
    return Array(UnsafeBufferPointer(start: out, count: Int(len)))
  }

  // MARK: - mg 签名（对标 mg/musicSearch.js createSignature）
  static func mgSign(time: String, keyword: String) -> (sign: String, deviceId: String) {
    let deviceId = "963B7AA0D21511ED807EE5846EC87D20"
    let sign = md5("\(keyword)6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50\(deviceId)\(time)")
    return (sign, deviceId)
  }
}

// 简易 HTTP（免签接口用；签名接口各自组装）
enum iMusicHttp {
  static func getJSON(_ urlString: String, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> Any {
    var req = URLRequest(url: URL(string: urlString)!, timeoutInterval: timeout)
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONSerialization.jsonObject(with: data)
  }

  static func postJSON(_ urlString: String, json: [String: Any], headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> Any {
    var req = URLRequest(url: URL(string: urlString)!, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = try JSONSerialization.data(withJSONObject: json)
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONSerialization.jsonObject(with: data)
  }

  static func postForm(_ urlString: String, form: [String: String], headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> Any {
    var req = URLRequest(url: URL(string: urlString)!, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
      .joined(separator: "&").data(using: .utf8)
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONSerialization.jsonObject(with: data)
  }
}