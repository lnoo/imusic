import Foundation
import CryptoKit
import CommonCrypto

// MARK: - 签名与格式化小工具
// 对标：renderer/utils/index.ts(sizeFormate/formatPlayTime/decodeName)
//      wy/utils/crypto.js(eapi) / mg/musicSearch.js(createSignature)
//      （tx zzcSign 签名随 DoSearchForQQMusicDesktop 端点失效一并下线，改走免签名的 DoSearchForQQMusicMobile）

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

  /// HTML 反转义（对标 decodeName；原实现实体字面量损坏导致整串替换失效，本次修复）
  static func decode(_ s: String) -> String {
    let entities = [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&39;", "'"), ("&#039;", "'")]
    var out = s
    for (e, v) in entities { out = out.replacingOccurrences(of: e, with: v) }
    return out
  }

  static func mmss(_ sec: Int) -> String {
    guard sec > 0 else { return "00:00" }
    return String(format: "%02d:%02d", sec / 60, sec % 60)
  }

  static func singerNames(_ arr: [[String: Any]]) -> String {
    arr.compactMap { $0["name"] as? String }.joined(separator: "、")
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