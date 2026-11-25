import Foundation
import CryptoKit
import CommonCrypto

// MARK: - any-listen 扩展侧加密助手原生移植（只读参考，不改动 submodule）
//
// 参考源文件（均为 READ-ONLY submodule，仅作语义参照）：
//   extensions/online-metadata/src/onlineResource/wy/utils/crypto.ts   —— weapi / eapi / linuxapi
//   extensions/online-metadata/src/onlineResource/wy/utils/index.ts    —— weapiRequest（调用 weapi）
//   extensions/online-metadata/src/onlineResource/kw/util.ts           —— wbdCrypto（AES ECB + MD5 签名）
//   extensions/online-metadata/src/onlineResource/kg/utils.ts          —— signatureParams
//   extensions/online-metadata/src/onlineResource/mg/utils/mrc.ts      —— TEA decrypt（mrc 歌词）
//   any-listen/packages/shared/app/modules/worker/extensionService/vm/hostContext/hostFuncs.ts
//       —— hostApi 的 crypto.aesEncrypt / rsaEncrypt / md5 真实实现（决定填充与输出编码）
//
// 全部为无状态静态函数，Swift 6 Sendable 安全。
enum ALCrypto: Sendable {

  // MARK: - 基础编码

  /// 16 进制（小写）；对标 crypto.ts 中各处 `dataConverter(..., 'base64', 'hex')` 的输出
  static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  /// 从 16 进制字符串转 Data（奇数长度自动补前导 0）
  static func dataFromHex(_ s: String) -> Data? {
    var text = s
    if text.count % 2 != 0 { text = "0" + text }
    guard text.count % 2 == 0 else { return nil }
    var out = Data()
    var i = text.startIndex
    while i < text.endIndex {
      let j = text.index(i, offsetBy: 2)
      guard let b = UInt8(text[i..<j], radix: 16) else { return nil }
      out.append(b)
      i = j
    }
    return out
  }

  /// base64 转 URL-safe（去掉 =，+/ 换成 -_）；wx/qrc 等接口需要
  static func b64URLSafe(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  // MARK: - MD5

  /// crypto.ts:49 `crypto.md5(message)` / kw/util.ts:123 `crypto.md5(str)`
  static func md5(_ s: String) -> String {
    md5Hex(Data(s.utf8))
  }

  static func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - AES

  /// 把任意长度 key 规整成 AES-128 的 16 字节（不足补 0，超出截断）
  private static func aesKey16(_ key: Data) -> Data {
    if key.count == kCCKeySizeAES128 { return key }
    if key.count > kCCKeySizeAES128 { return key.prefix(kCCKeySizeAES128) }
    var k = key
    k.append(contentsOf: [UInt8](repeating: 0, count: kCCKeySizeAES128 - k.count))
    return k
  }

  /// 底层 CCCrypt 封装。options 由调用方给定（ECB 路径只传 kCCOptionECBMode，即 NO padding）
  private static func crypt(_ data: Data, key: Data, iv: Data?, options: CCOptions,
                            operation: CCOperation) -> Data {
    guard !data.isEmpty else { return Data() }
    let k = aesKey16(key)
    // 注意：iv 缓冲区必须在 CCCrypt 调用期间保持存活；不能先 withUnsafeBytes
    // 取出裸指针再调用（那样闭包返回后指针即失效，CBC 会偶发密文错误）。
    let ivBytes = iv.map { [UInt8]($0) }
    let capacity = data.count + kCCBlockSizeAES128
    var output = [UInt8](repeating: 0, count: capacity)
    var outputLength: size_t = 0
    let status = k.withUnsafeBytes { kp in
      data.withUnsafeBytes { dp in
        output.withUnsafeMutableBytes { op in
          if let ivBytes {
            return ivBytes.withUnsafeBytes { vp in
              CCCrypt(operation,
                      CCAlgorithm(kCCAlgorithmAES),
                      options,
                      kp.baseAddress, kCCKeySizeAES128,
                      vp.baseAddress,
                      dp.baseAddress, data.count,
                      op.baseAddress, capacity, &outputLength)
            }
          }
          return CCCrypt(operation,
                         CCAlgorithm(kCCAlgorithmAES),
                         options,
                         kp.baseAddress, kCCKeySizeAES128,
                         nil,
                         dp.baseAddress, data.count,
                         op.baseAddress, capacity, &outputLength)
        }
      }
    }
    guard status == kCCSuccess else { return Data() }
    return Data(output[0..<Int(outputLength)])
  }

  // ECB（wy eapi / kw wbdCrypto）------------------------------------------------

  /// AES-128-ECB 原始块加密（NO padding，CCCrypt options 仅为 kCCOptionECBMode）。
  /// 输入不足 16 字节整块时补 0 到整块；适合已知向量/自研协议。
  /// 扩展侧实际走的是 `aes-128-ecb` + Node 默认 autoPadding=true（见下方 aesECBEncrypt 注释），
  /// 需要与其 wire 兼容请使用 `aesECBEncrypt`。
  static func aesECBRawEncrypt(_ data: Data, key: Data) -> Data {
    var aligned = data
    let rem = aligned.count % kCCBlockSizeAES128
    if rem != 0 {
      aligned.append(contentsOf: [UInt8](repeating: 0, count: kCCBlockSizeAES128 - rem))
    }
    return crypt(aligned, key: key, iv: nil,
                 options: CCOptions(kCCOptionECBMode), operation: CCOperation(kCCEncrypt))
  }

  /// AES-128-ECB 原始块解密（NO padding）；返回整块字节，调用方自行去填充
  static func aesECBRawDecrypt(_ data: Data, key: Data) -> Data {
    crypt(data, key: key, iv: nil,
          options: CCOptions(kCCOptionECBMode), operation: CCOperation(kCCDecrypt))
  }

  /// AES-128-ECB + PKCS7 填充，与扩展语义完全一致。
  ///
  /// 说明：crypto.ts:42/52 与 kw/util.ts:118/129 写的是 `'ECB_128_NoPadding'`，
  /// 但 hostFuncs.ts:115-138 把它映射成 Node 的 `aes-128-ecb`，且 `createCipheriv`
  /// 默认 `setAutoPadding(true)`，因此实际密文是 PKCS7 填充的。这里用 CCCrypt 的
  /// NO padding 选项（`CCOptions(0)`）+ 手动 PKCS7，得到逐字节相同的结果。
  static func aesECBEncrypt(_ data: Data, key: Data) -> Data {
    crypt(pkcs7Pad(data), key: key, iv: nil,
          options: CCOptions(kCCOptionECBMode), operation: CCOperation(kCCEncrypt))
  }

  /// AES-128-ECB + PKCS7 去填充（扩展侧 `aesDecrypt('ECB_128_NoPadding', ..., 'utf-8')` 等价）
  static func aesECBDecrypt(_ data: Data, key: Data) -> Data {
    let raw = crypt(data, key: key, iv: nil,
                    options: CCOptions(kCCOptionECBMode), operation: CCOperation(kCCDecrypt))
    return pkcs7Unpad(raw) ?? raw
  }

  private static func pkcs7Pad(_ data: Data) -> Data {
    let pad = kCCBlockSizeAES128 - (data.count % kCCBlockSizeAES128) // 1...16
    var out = data
    out.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
    return out
  }

  private static func pkcs7Unpad(_ data: Data) -> Data? {
    guard !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else { return nil }
    let pad = Int(data[data.count - 1])
    guard pad > 0, pad <= kCCBlockSizeAES128, pad <= data.count else { return nil }
    for i in (data.count - pad)..<data.count where data[i] != UInt8(pad) { return nil }
    return data.prefix(data.count - pad)
  }

  // CBC（wy weapi）--------------------------------------------------------------

  /// AES-128-CBC + PKCS7，对标 crypto.ts:30/32 的 `'CBC_128_PKCS7Padding'`（hostFuncs.ts:116 `aes-128-cbc`）
  static func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) -> Data {
    crypt(data, key: key, iv: iv,
          options: CCOptions(kCCOptionPKCS7Padding), operation: CCOperation(kCCEncrypt))
  }

  static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data {
    crypt(data, key: key, iv: iv,
          options: CCOptions(kCCOptionPKCS7Padding), operation: CCOperation(kCCDecrypt))
  }

  // MARK: - RSA（无填充，wy weapi encSecKey）

  /// wy crypto.ts:10 PEM 公钥解出的模数（1024 bit，含前导 00 共 128 字节），
  /// 即 netease 经典 modulus；指数为 010001 = 65537。
  static let weapiModulusHex =
    "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa" +
    "76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a" +
    "46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"

  /// RSA_NO_PADDING 的 m^e mod n（纯 Swift 大整数，无外部依赖）。
  ///
  /// 对标 hostFuncs.ts:165-181 `utils_rsa_encrypt`：Node 在 publicEncrypt 前会
  /// `Buffer.concat([Buffer.alloc(128 - dataBuf.length), dataBuf])`，即**左侧补 0 到
  /// 模数字节长度**。这里同样补零，保证 encSecKey 为固定 128 字节。
  static func rsaNoPaddingEncrypt(_ data: Data, modulusHex: String, exponentHex: String) -> Data {
    guard var nBytes = dataFromHex(modulusHex),
          let e = dataFromHex(exponentHex), !nBytes.isEmpty else { return Data() }
    // modulusHex 来自 ASN.1 INTEGER，可能带 1 字节符号位 0x00；
    // Node 的 RSA 块长度取「模数实际字节数」（1024 bit -> 128），不是含符号位的长度。
    let n = bigNormalize([UInt8](nBytes))
    guard !n.isEmpty else { return Data() }
    let modulusByteCount = n.count

    var m = Data(data)
    if m.count < modulusByteCount {
      m = Data(repeating: 0, count: modulusByteCount - m.count) + m
    }
    let result = bigModPow(bigNormalize([UInt8](m)), bigNormalize([UInt8](e)), n)
    nBytes = Data([UInt8](repeating: 0, count: max(0, modulusByteCount - result.count)) + result)
    return Data(nBytes.prefix(modulusByteCount))
  }

  // 大整数辅助：大端 [UInt8]，空数组表示 0；全程 mod 2^(8*count) 语义

  private static func bigNormalize(_ x: [UInt8]) -> [UInt8] {
    var i = 0
    while i < x.count && x[i] == 0 { i += 1 }
    return i == 0 ? x : Array(x[i...])
  }

  private static func bigCompare(_ a: [UInt8], _ b: [UInt8]) -> Int {
    if a.count != b.count { return a.count < b.count ? -1 : 1 }
    for i in 0..<a.count where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
    return 0
  }

  private static func bigAdd(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    let n = max(a.count, b.count)
    var out = [UInt8](repeating: 0, count: n + 1)
    var carry = 0
    // i 从最低位（数组末尾）向最高位推进，进位方向必须 LSB -> MSB
    for i in 0..<n {
      let av = i < a.count ? Int(a[a.count - 1 - i]) : 0
      let bv = i < b.count ? Int(b[b.count - 1 - i]) : 0
      let s = av + bv + carry
      out[out.count - 1 - i] = UInt8(s & 0xff)
      carry = s >> 8
    }
    out[0] = UInt8(carry)
    return bigNormalize(out)
  }

  /// a >= b 时返回 a - b；借位方向同样必须 LSB -> MSB
  private static func bigSub(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var out = a
    var borrow = 0
    for i in 0..<a.count {
      let bv = i < b.count ? Int(b[b.count - 1 - i]) : 0
      var v = Int(a[a.count - 1 - i]) - bv - borrow
      if v < 0 { v += 256; borrow = 1 } else { borrow = 0 }
      out[a.count - 1 - i] = UInt8(v)
    }
    return bigNormalize(out)
  }

  private static func bigMul(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    if a.isEmpty || b.isEmpty { return [] }
    var out = [UInt8](repeating: 0, count: a.count + b.count)
    for i in 0..<a.count {
      var carry = 0
      let av = Int(a[a.count - 1 - i])
      for j in 0..<b.count {
        let idx = out.count - 1 - (i + j)
        let t = av * Int(b[b.count - 1 - j]) + Int(out[idx]) + carry
        out[idx] = UInt8(t & 0xff)
        carry = t >> 8
      }
      out[out.count - 1 - (i + b.count)] = UInt8(carry)
    }
    return bigNormalize(out)
  }

  private static func bigShiftLeftOne(_ x: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: x.count)
    var carry: UInt8 = 0
    for i in stride(from: x.count - 1, through: 0, by: -1) {
      out[i] = (x[i] << 1) | carry
      carry = x[i] >> 7
    }
    if carry != 0 { out.insert(carry, at: 0) }
    return bigNormalize(out)
  }

  private static func bigShiftRightOne(_ x: [UInt8]) -> [UInt8] {
    var out = x
    var carry: UInt8 = 0
    for i in 0..<x.count {
      let v = x[i]
      out[i] = (v >> 1) | carry
      carry = (v & 1) << 7
    }
    return bigNormalize(out)
  }

  /// 逐位长除法求 a mod n
  private static func bigMod(_ a: [UInt8], _ n: [UInt8]) -> [UInt8] {
    var rem: [UInt8] = []
    for byte in a {
      for bit in stride(from: 7, through: 0, by: -1) {
        rem = bigShiftLeftOne(rem)
        let b = (byte >> UInt8(bit)) & 1
        if rem.isEmpty {
          if b != 0 { rem = [1] }
        } else {
          rem[rem.count - 1] |= b
        }
        if bigCompare(rem, n) >= 0 { rem = bigSub(rem, n) }
      }
    }
    return rem
  }

  private static func bigModPow(_ base: [UInt8], _ exp: [UInt8], _ mod: [UInt8]) -> [UInt8] {
    var result: [UInt8] = [1]
    var b = bigMod(base, mod)
    var e = exp
    while !e.isEmpty {
      if (e[e.count - 1] & 1) != 0 { result = bigMod(bigMul(result, b), mod) }
      e = bigShiftRightOne(e)
      if !e.isEmpty { b = bigMod(bigMul(b, b), mod) }
    }
    return result
  }

  // MARK: - weapi 参数（wy crypto.ts:25-37 + wy/index.ts:33-53）

  /// 完全对齐 `weapi(object)`：
  ///   1. text = JSON.stringify(object)
  ///   2. secretKey = String(Math.random()).substring(2, 18) —— 16 位随机十进制数字
  ///   3. params = base64(AES-CBC-PKCS7(base64(AES-CBC-PKCS7(text, presetKey, iv), secretKey, iv))
  ///   4. encSecKey = hex(RSA_NO_PADDING(reverse(secretKey)), 经典 1024 bit 公钥)
  ///
  /// - Parameter url: 参考实现的 `weapi(object)` 并不使用 url（eapi 才用）；保留以对齐调用方签名。
  static func weapiParams(_ object: [String: Any], url: String) -> (params: String, encSecKey: String) {
    _ = url
    let text: String
    if let raw = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let s = String(data: raw, encoding: .utf8) {
      text = s
    } else {
      text = "{}"
    }

    let presetKey = "0CoJUm6Qyw8W8jud"
    let iv = "0102030405060708"
    let secret = (0..<16).map { _ in String(UInt32.random(in: 0...9)) }.joined()

    let first = aesCBCEncrypt(Data(text.utf8), key: Data(presetKey.utf8), iv: Data(iv.utf8))
    let firstB64 = first.base64EncodedString()
    let second = aesCBCEncrypt(Data(firstB64.utf8), key: Data(secret.utf8), iv: Data(iv.utf8))
    let params = second.base64EncodedString()

    // secretKey.reverse() 是原地反转字节（ASCII 数字），随后 hostApi 左侧补 0 至 128 字节
    let reversedSecret = Data(Data(secret.utf8).reversed())
    let encrypted = rsaNoPaddingEncrypt(reversedSecret,
                                        modulusHex: Self.weapiModulusHex,
                                        exponentHex: "010001")
    return (params, hex(encrypted))
  }

  // MARK: - 酷狗签名（kg/utils.ts:12-19）

  /// 对齐 `signatureParams(params, platform, body)`：
  ///   keyparam + sorted(`params.split('&').join('')`) + body + keyparam，取 md5。
  /// 注意扩展源码是 `paramList.join('')`（空串拼接），不是 `&`。
  static func kgSignature(_ params: String, body: String = "", platform: String = "android") -> String {
    let keyparam = platform == "web"
      ? "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt"
      : "OIlwieks28dk2k092lksi2UIkp"
    let sorted = params.split(separator: "&", omittingEmptySubsequences: false).sorted().joined()
    return md5("\(keyparam)\(sorted)\(body)\(keyparam)")
  }

  // MARK: - 咪咕 TEA（mg/utils/mrc.ts:1-97）

  /// mrc.ts:6-16 的 9 个 16-hex-char key（源码里是十进制 bigint 字面量，这里写成其等价 hex）
  static let teaKeyHex = [
    "006100720061006b", "0040006c0061006b", "0051003300320031",
    "0079006d006f0063", "006e006f00640069", "0061006900740067",
    "006100690074006e", "006f00610068006e", "0067006e00690074",
  ]

  /// 对标 `teaDecrypt(data, key)`，输出为 8 字节小端块的连续字节流（调用方按 utf16le 解码）。
  /// - Parameter data: 十六进制文本字节（`Data(hexString.utf8)`），每 16 个 hex 字符解析成一个 64 位字。
  /// - Parameter keyHex: 16-hex-char 的 key 数组，默认 `teaKeyHex`。
  static func teaDecrypt(_ data: Data, keyHex: [String] = ALCrypto.teaKeyHex) -> Data? {
    let text = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty, text.count % 16 == 0 else { return nil }

    var words: [UInt64] = []
    var i = text.startIndex
    while i < text.endIndex {
      let j = text.index(i, offsetBy: 16)
      guard let v = UInt64(text[i..<j], radix: 16) else { return nil }
      words.append(v)
      i = j
    }
    let keys = keyHex.compactMap { UInt64($0, radix: 16) }
    guard keys.count >= 4 else { return nil }

    teaDecryptWords(&words, keys: keys)

    var out = Data()
    for w in words {
      // mrc.ts longToBytes：低字节在前（小端）
      for shift in stride(from: 0, to: 64, by: 8) {
        out.append(UInt8(truncatingIfNeeded: w >> UInt64(shift)))
      }
    }
    return out
  }

  /// 逐字翻译 mrc.ts:53-92。JS 的 BigInt 运算均在 2^64 取模（toLong），
  /// 故用 UInt64 的 &+ / &- / &* / &<< 与算术右移即可逐位等价。
  private static func teaDecryptWords(_ data: inout [UInt64], keys: [UInt64]) {
    let length = data.count
    guard length >= 1 else { return }
    let delta: UInt64 = 2654435769
    let lengthU = UInt64(length)

    var j2 = data[0]
    var j3 = (6 &+ 52 / lengthU) &* delta

    while true {
      let j4 = j3
      if j4 == 0 { break }
      let j5: UInt64 = 3 & sar(j4, 2)
      var j6 = length
      while true {
        j6 -= 1
        if j6 <= 0 { break }
        let j7 = data[j6 - 1]
        let idx = j6
        let keyIdx = Int((3 & UInt64(j6)) ^ j5)
        let sumA = (j2 ^ j4) &+ (j7 ^ keys[keyIdx])
        let sumB = (sar(j7, 5) ^ (j2 &<< 2)) &+ (sar(j2, 3) ^ (j7 &<< 4))
        j2 = data[idx] &- (sumA ^ sumB)
        data[idx] = j2
      }
      let j8 = data[length - 1]
      let keyIdx = Int((UInt64(j6) & 3) ^ j5) // j6 == 0
      let sumA = (keys[keyIdx] ^ j8) &+ (j2 ^ j4)
      let sumB = (sar(j8, 5) ^ (j2 &<< 2)) &+ (sar(j2, 3) ^ (j8 &<< 4))
      j2 = data[0] &- (sumA ^ sumB)
      data[0] = j2
      j3 = j4 &- delta
    }
  }

  /// JS BigInt 的算术右移（负数高位补 1）
  private static func sar(_ x: UInt64, _ bits: Int) -> UInt64 {
    UInt64(bitPattern: Int64(bitPattern: x) >> bits)
  }
}

// MARK: - ALHttp 扩展（不改动 AnyListenResource.swift）
//
// 复用 ALHttp 的错误类型与 User-Agent 约定，补齐扩展侧常用的
// `request(..., form:)` 与原始二进制 POST 能力。

extension ALHttp {
  /// application/x-www-form-urlencoded POST（对齐扩展 hostApi 的 form 请求）。
  /// key/value 均按 unreserved 字符集 percent-encode（对标 `encodeURIComponent`）。
  static func postForm(_ urlString: String,
                       form: [(String, String)],
                       headers: [String: String] = [:],
                       timeout: TimeInterval = 15) async throws -> Any {
    guard let url = URL(string: urlString) else {
      throw ALSourceError.invalidResponse("无效 URL: \(urlString)")
    }
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let body = form.map { k, v in
      let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
      let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
      return "\(ek)=\(ev)"
    }.joined(separator: "&")

    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = Data(body.utf8)

    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONSerialization.jsonObject(with: data)
  }

  /// 原始二进制 POST（wy eapi 等需要自己组装 body / Content-Type 时使用）
  static func postRaw(_ urlString: String,
                      body: Data,
                      headers: [String: String] = [:],
                      timeout: TimeInterval = 15) async throws -> (data: Data, response: HTTPURLResponse) {
    guard let url = URL(string: urlString) else {
      throw ALSourceError.invalidResponse("无效 URL: \(urlString)")
    }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
      throw ALSourceError.invalidResponse("非 HTTP 响应")
    }
    return (data, http)
  }
}
