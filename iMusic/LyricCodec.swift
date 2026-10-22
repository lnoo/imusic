import Foundation
import Compression

// MARK: - 歌词加密格式解码（音源底层 · any-listen 生态同款）
//
// kg KRC：lyrics.kugou.com download?fmt=krc → base64 → 头 4 字节 "krc1" +
//         循环 XOR（key = "@Gaw^2tGQ61-ÎÊni"，即 [64,71,97,119,94,50,116,71,
//         81,54,49,45,206,210,110,105]）→ zlib inflate → KRC/逐字歌词。
//         （参考 CGQAQ/krc-rs、lx-music 系 decodeKrc）
//
// tx QRC：u.y.qq.com GetPlayLyricInfo → lyric 为 hex(QRC密文) →
//         pyqdes 三段式（ddes KEY1 → des KEY2 → ddes KEY3）→ zlib inflate →
//         XML 包裹的逐字歌词（参考 TLittlePrince/qrcDecrypt，
//         算法源自 qq49371114/lx-music-api-server 的 pyqdes）。
//
// 二者均为公开社区早已广泛流传的格式，仅用于正常展示歌词。

enum LyricCodec {
  // MARK: zlib inflate（兼容 zlib 头与裸 deflate）

  static func zlibInflate(_ data: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    // 带 RFC1950 zlib 头（0x78xx）时，先剥头再按裸 deflate 解（Apple COMPRESSION_ZLIB 为裸 deflate）
    if data.count > 6, data[data.startIndex] == 0x78 {
      if let out = try? SourceScriptParser.decompress(Data(data.dropFirst(2))), !out.isEmpty { return out }
    }
    if let out = try? SourceScriptParser.decompress(data), !out.isEmpty { return out }
    return nil
  }

  // MARK: KRC（酷狗逐字歌词）

  private static let krcKey: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71,
                                        81, 54, 49, 45, 206, 210, 110, 105]

  static func decodeKRC(_ data: Data) -> String? {
    guard data.count > 4 else { return nil }
    let bytes = [UInt8](data)
    guard String(bytes: bytes[0..<4], encoding: .ascii) == "krc1" else { return nil }
    var out = [UInt8](repeating: 0, count: bytes.count - 4)
    for i in 4..<bytes.count {
      out[i - 4] = bytes[i] ^ krcKey[(i - 4) % krcKey.count]
    }
    guard let inflated = zlibInflate(Data(out)) else { return nil }
    return String(data: inflated, encoding: .utf8)
  }

  /// KRC 逐字行转 LRC（[mm:ss.xxx]<dur,0,0>词）：供 LrcParser 统一消费
  static func krcToLrc(_ krc: String) -> String {
    var lines: [String] = []
    let rxp = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
    for raw in krc.components(separatedBy: .newlines) {
      let ns = raw as NSString
      guard let m = rxp.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
      let start = Int(ns.substring(with: m.range(at: 1))) ?? 0
      let ms = start % 1000, total = start / 1000
      let mm = total / 60, ss = total % 60
      let stamp = String(format: "[%02d:%02d.%03d]", mm, ss, ms)
      // <dur,offset,0> 为逐字时长标签：LrcParser 会剔除标签，文本保留
      lines.append(stamp + ns.substring(with: m.range(at: 3)))
    }
    return lines.joined(separator: "\n")
  }

  // MARK: QRC（QQ音乐逐字歌词，pyqdes）

  static func decodeQRC(_ encoded: String) -> String? {
    var cipher: [UInt8]
    var hex = encoded.uppercased()
    if hex.hasPrefix("QRC") { hex = String(hex.dropFirst(3)) }
    if hex.count > 8, hex.count % 2 == 0, hex.allSatisfy({ $0.isHexDigit }) {
      var b: [UInt8] = []
      var i = hex.startIndex
      while i < hex.endIndex {
        guard let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), next <= hex.endIndex else { break }
        b.append(UInt8(hex[i..<next], radix: 16) ?? 0)
        i = next
      }
      cipher = b
    } else if let d = Data(base64Encoded: encoded) {
      cipher = [UInt8](d)
    } else {
      return nil
    }
    guard cipher.count > 8, cipher.count % 8 == 0 else { return nil }
    QrcDes.lyricDecode(&cipher)
    guard let inflated = zlibInflate(Data(cipher)),
          let text = String(data: inflated, encoding: .utf8) else { return nil }
    return extractQrcBody(text)
  }

  /// QRC 常为 <?xml ...><QrcInfos>... 包裹，取出正文（无包裹则原样返回）
  static func extractQrcBody(_ text: String) -> String {
    if let s = text.range(of: "<Lyric_1>"), let e = text.range(of: "</Lyric_1>", range: s.upperBound..<text.endIndex) {
      return String(text[s.upperBound..<e.lowerBound])
    }
    return text
  }

  /// QRC 行 → LRC：`[lineStartMs,durMs]词(x,y)词(x,y)` → `[mm:ss.mmm]词词`
  /// （lyric 供展示：剔除 (x,y) 逐字标签；lxlyric 为 <x,y> 逐字版）
  static func qrcToLrc(_ qrc: String) -> (lyric: String, lxlyric: String?) {
    let lineExp = try! NSRegularExpression(pattern: #"\[(-?\d+),(-?\d+)\]"#)
    let wordExp = try! NSRegularExpression(pattern: #"\((\d+),(\d+)\)"#)
    var lyricLines: [String] = []
    var lxLines: [String] = []
    var tags: [String] = []
    for line in qrc.components(separatedBy: .newlines) {
      let ns = line as NSString
      guard let lm = lineExp.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[ti:") || t.hasPrefix("[ar:") || t.hasPrefix("[al:")
            || t.hasPrefix("[by:") || t.hasPrefix("[offset:") {
          tags.append(t)
        }
        continue
      }
      let startMs = Int(ns.substring(with: lm.range(at: 1))) ?? 0
      let mm = startMs / 60000, ss = startMs % 60000 / 1000, ms = startMs % 1000
      let stamp = String(format: "[%02d:%02d.%03d]", mm, ss, ms)
      let rest = ns.substring(from: lm.range.upperBound)
      let restNS = rest as NSString
      let plain = wordExp.stringByReplacingMatches(in: rest, options: [], range: NSRange(location: 0, length: restNS.length),
                                                   withTemplate: "").trimmingCharacters(in: .whitespaces)
      let lxRest = wordExp.stringByReplacingMatches(in: rest, options: [], range: NSRange(location: 0, length: restNS.length),
                                                     withTemplate: "")
        .replacingOccurrences(of: "(", with: "<").replacingOccurrences(of: ")", with: ">")
      if !plain.isEmpty {
        lyricLines.append(stamp + plain)
        lxLines.append(stamp + lxRest.trimmingCharacters(in: .whitespaces))
      }
    }
    let head = tags.isEmpty ? "" : (tags.joined(separator: "\n") + "\n")
    let lyric = head + lyricLines.joined(separator: "\n")
    let lx = head + lxLines.joined(separator: "\n")
    return (lyric, lxLines.isEmpty ? nil : lx)
  }
}

// MARK: - pyqdes（QQ QRC 三重自定义 DES）

/// 端口自 pyqdes（QQ 音乐 QRC 逆向实现，Python/Cpp 版社区公开）。
/// 所有位运算按 Python 无符号语义用 UInt32/UInt8 复刻。
enum QrcDes {
  private static let sBox1: [UInt8] = [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
    0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
    4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
    15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13]
  private static let sBox2: [UInt8] = [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
    3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
    0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
    13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9]
  private static let sBox3: [UInt8] = [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
    13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
    13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
    1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12]
  private static let sBox4: [UInt8] = [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
    13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
    10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
    3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14]
  private static let sBox5: [UInt8] = [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
    14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
    4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
    11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3]
  private static let sBox6: [UInt8] = [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
    10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
    9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
    4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13]
  private static let sBox7: [UInt8] = [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
    13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
    1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
    6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12]
  private static let sBox8: [UInt8] = [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
    1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
    7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
    2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]

  private static let key1: [UInt8] = Array("!@#)(NHLiuy*$%^&".utf8)
  private static let key2: [UInt8] = Array("123ZXC!@#)(*$%^&".utf8)
  private static let key3: [UInt8] = Array("!@#)(*$%^&abcDEF".utf8)

  private static let keyRndShift: [UInt32] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
  private static let keyPermC: [Int] = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17,
                                         9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
  private static let keyPermD: [Int] = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21,
                                         13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
  private static let keyCompression: [Int] = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9,
                                              22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1,
                                              40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47,
                                              43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]

  private static func bitNum(_ a: [UInt8], _ b: Int, _ c: Int) -> UInt32 {
    let byteIndex = (b / 32) * 4 + 3 - (b % 32) / 8
    let bitPosition = UInt8(7 - (b % 8))
    let extracted = (a[byteIndex] >> bitPosition) & 0x01
    return UInt32(extracted) << c
  }

  private static func bitNumIntR(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
    let extracted = (a >> UInt32(31 - b)) & 0x00000001
    return extracted << c
  }

  private static func bitNumIntL(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
    let extracted = (a << UInt32(b)) & 0x80000000
    return extracted >> c
  }

  private static func sBoxBit(_ a: UInt8) -> Int {
    let part1 = a & 0x20
    let part2 = (a & 0x1f) >> 1
    let part3 = (a & 0x01) << 4
    return Int(part1 | part2 | part3)
  }

  private static func ip(_ state: inout [UInt32], _ inBytes: [UInt8]) {
    state[0] = bitNum(inBytes, 57, 31) | bitNum(inBytes, 49, 30) | bitNum(inBytes, 41, 29)
      | bitNum(inBytes, 33, 28) | bitNum(inBytes, 25, 27) | bitNum(inBytes, 17, 26)
      | bitNum(inBytes, 9, 25) | bitNum(inBytes, 1, 24) | bitNum(inBytes, 59, 23)
      | bitNum(inBytes, 51, 22) | bitNum(inBytes, 43, 21) | bitNum(inBytes, 35, 20)
      | bitNum(inBytes, 27, 19) | bitNum(inBytes, 19, 18) | bitNum(inBytes, 11, 17)
      | bitNum(inBytes, 3, 16) | bitNum(inBytes, 61, 15) | bitNum(inBytes, 53, 14)
      | bitNum(inBytes, 45, 13) | bitNum(inBytes, 37, 12) | bitNum(inBytes, 29, 11)
      | bitNum(inBytes, 21, 10) | bitNum(inBytes, 13, 9) | bitNum(inBytes, 5, 8)
      | bitNum(inBytes, 63, 7) | bitNum(inBytes, 55, 6) | bitNum(inBytes, 47, 5)
      | bitNum(inBytes, 39, 4) | bitNum(inBytes, 31, 3) | bitNum(inBytes, 23, 2)
      | bitNum(inBytes, 15, 1) | bitNum(inBytes, 7, 0)
    state[1] = bitNum(inBytes, 56, 31) | bitNum(inBytes, 48, 30) | bitNum(inBytes, 40, 29)
      | bitNum(inBytes, 32, 28) | bitNum(inBytes, 24, 27) | bitNum(inBytes, 16, 26)
      | bitNum(inBytes, 8, 25) | bitNum(inBytes, 0, 24) | bitNum(inBytes, 58, 23)
      | bitNum(inBytes, 50, 22) | bitNum(inBytes, 42, 21) | bitNum(inBytes, 34, 20)
      | bitNum(inBytes, 26, 19) | bitNum(inBytes, 18, 18) | bitNum(inBytes, 10, 17)
      | bitNum(inBytes, 2, 16) | bitNum(inBytes, 60, 15) | bitNum(inBytes, 52, 14)
      | bitNum(inBytes, 44, 13) | bitNum(inBytes, 36, 12) | bitNum(inBytes, 28, 11)
      | bitNum(inBytes, 20, 10) | bitNum(inBytes, 12, 9) | bitNum(inBytes, 4, 8)
      | bitNum(inBytes, 62, 7) | bitNum(inBytes, 54, 6) | bitNum(inBytes, 46, 5)
      | bitNum(inBytes, 38, 4) | bitNum(inBytes, 30, 3) | bitNum(inBytes, 22, 2)
      | bitNum(inBytes, 14, 1) | bitNum(inBytes, 6, 0)
  }

  private static func invIP(_ state: [UInt32], _ out: inout [UInt8]) {
    func byteAt(_ pairs: [(Int, Int, Int)]) -> UInt8 {
      var v: UInt32 = 0
      for (s, b, c) in pairs { v |= bitNumIntR(state[s], b, c) }
      return UInt8(v & 0xff)
    }
    out[3] = byteAt([(1, 7, 7), (0, 7, 6), (1, 15, 5), (0, 15, 4), (1, 23, 3), (0, 23, 2), (1, 31, 1), (0, 31, 0)])
    out[2] = byteAt([(1, 6, 7), (0, 6, 6), (1, 14, 5), (0, 14, 4), (1, 22, 3), (0, 22, 2), (1, 30, 1), (0, 30, 0)])
    out[1] = byteAt([(1, 5, 7), (0, 5, 6), (1, 13, 5), (0, 13, 4), (1, 21, 3), (0, 21, 2), (1, 29, 1), (0, 29, 0)])
    out[0] = byteAt([(1, 4, 7), (0, 4, 6), (1, 12, 5), (0, 12, 4), (1, 20, 3), (0, 20, 2), (1, 28, 1), (0, 28, 0)])
    out[7] = byteAt([(1, 3, 7), (0, 3, 6), (1, 11, 5), (0, 11, 4), (1, 19, 3), (0, 19, 2), (1, 27, 1), (0, 27, 0)])
    out[6] = byteAt([(1, 2, 7), (0, 2, 6), (1, 10, 5), (0, 10, 4), (1, 18, 3), (0, 18, 2), (1, 26, 1), (0, 26, 0)])
    out[5] = byteAt([(1, 1, 7), (0, 1, 6), (1, 9, 5), (0, 9, 4), (1, 17, 3), (0, 17, 2), (1, 25, 1), (0, 25, 0)])
    out[4] = byteAt([(1, 0, 7), (0, 0, 6), (1, 8, 5), (0, 8, 4), (1, 16, 3), (0, 16, 2), (1, 24, 1), (0, 24, 0)])
  }

  private static func f(_ stateIn: UInt32, _ key: [Int]) -> UInt32 {
    var lrgstate = [UInt32](repeating: 0, count: 6)
    let state = stateIn
    // Expansion Permutation
    let t1: UInt32 = bitNumIntL(state, 31, 0) | ((state & 0xf0000000) >> 1) | bitNumIntL(state, 4, 5)
      | bitNumIntL(state, 3, 6) | ((state & 0x0f000000) >> 3) | bitNumIntL(state, 8, 11)
      | bitNumIntL(state, 7, 12) | ((state & 0x00f00000) >> 5) | bitNumIntL(state, 12, 17)
      | bitNumIntL(state, 11, 18) | ((state & 0x000f0000) >> 7) | bitNumIntL(state, 16, 23)
    let t2: UInt32 = bitNumIntL(state, 15, 0) | ((state & 0x0000f000) << 15) | bitNumIntL(state, 20, 5)
      | bitNumIntL(state, 19, 6) | ((state & 0x00000f00) << 13) | bitNumIntL(state, 24, 11)
      | bitNumIntL(state, 23, 12) | ((state & 0x000000f0) << 11) | bitNumIntL(state, 28, 17)
      | bitNumIntL(state, 27, 18) | ((state & 0x0000000f) << 9) | bitNumIntL(state, 0, 23)
    lrgstate[0] = (t1 >> 24) & 0x000000ff
    lrgstate[1] = (t1 >> 16) & 0x000000ff
    lrgstate[2] = (t1 >> 8) & 0x000000ff
    lrgstate[3] = (t2 >> 24) & 0x000000ff
    lrgstate[4] = (t2 >> 16) & 0x000000ff
    lrgstate[5] = (t2 >> 8) & 0x000000ff
    // Key XOR
    for i in 0..<6 { lrgstate[i] ^= UInt32(key[i]) }
    // S-Box Permutation
    var s: UInt32 =
      UInt32(sBox1[sBoxBit(UInt8((lrgstate[0] >> 2) & 0x3f))]) << 28
      | UInt32(sBox2[sBoxBit(UInt8(((lrgstate[0] & 0x03) << 4) | (lrgstate[1] >> 4)))]) << 24
      | UInt32(sBox3[sBoxBit(UInt8(((lrgstate[1] & 0x0f) << 2) | (lrgstate[2] >> 6)))]) << 20
      | UInt32(sBox4[sBoxBit(UInt8(lrgstate[2] & 0x3f))]) << 16
      | UInt32(sBox5[sBoxBit(UInt8((lrgstate[3] >> 2) & 0x3f))]) << 12
      | UInt32(sBox6[sBoxBit(UInt8(((lrgstate[3] & 0x03) << 4) | (lrgstate[4] >> 4)))]) << 8
      | UInt32(sBox7[sBoxBit(UInt8(((lrgstate[4] & 0x0f) << 2) | (lrgstate[5] >> 6)))]) << 4
      | UInt32(sBox8[sBoxBit(UInt8(lrgstate[5] & 0x3f))])
    // P-Box Permutation
    s = bitNumIntL(s, 15, 0) | bitNumIntL(s, 6, 1) | bitNumIntL(s, 19, 2)
      | bitNumIntL(s, 20, 3) | bitNumIntL(s, 28, 4) | bitNumIntL(s, 11, 5)
      | bitNumIntL(s, 27, 6) | bitNumIntL(s, 16, 7) | bitNumIntL(s, 0, 8)
      | bitNumIntL(s, 14, 9) | bitNumIntL(s, 22, 10) | bitNumIntL(s, 25, 11)
      | bitNumIntL(s, 4, 12) | bitNumIntL(s, 17, 13) | bitNumIntL(s, 30, 14)
      | bitNumIntL(s, 9, 15) | bitNumIntL(s, 1, 16) | bitNumIntL(s, 7, 17)
      | bitNumIntL(s, 23, 18) | bitNumIntL(s, 13, 19) | bitNumIntL(s, 31, 20)
      | bitNumIntL(s, 26, 21) | bitNumIntL(s, 2, 22) | bitNumIntL(s, 8, 23)
      | bitNumIntL(s, 18, 24) | bitNumIntL(s, 12, 25) | bitNumIntL(s, 29, 26)
      | bitNumIntL(s, 5, 27) | bitNumIntL(s, 21, 28) | bitNumIntL(s, 10, 29)
      | bitNumIntL(s, 3, 30) | bitNumIntL(s, 24, 31)
    return s
  }

  private static func desKeySetup(_ key: [UInt8], _ schedule: inout [[Int]], decrypt: Bool) {
    var c: UInt32 = 0, d: UInt32 = 0
    for i in 0..<28 {
      c |= bitNum(key, keyPermC[i], 31 - i)
      d |= bitNum(key, keyPermD[i], 31 - i)
    }
    for i in 0..<16 {
      let shift = keyRndShift[i]
      c = ((c << shift) | (c >> (28 - shift))) & 0xfffffff0
      d = ((d << shift) | (d >> (28 - shift))) & 0xfffffff0
      let toGen = decrypt ? 15 - i : i
      schedule[toGen] = [0, 0, 0, 0, 0, 0]
      for j in 0..<24 {
        schedule[toGen][j / 8] |= Int(bitNumIntR(c, keyCompression[j], 7 - (j % 8)))
      }
      for j in 24..<48 {
        schedule[toGen][j / 8] |= Int(bitNumIntR(d, keyCompression[j] - 27, 7 - (j % 8)))
      }
    }
  }

  private static func desBlock(_ inOut: inout [UInt8], _ schedule: [[Int]]) {
    var state: [UInt32] = [0, 0]
    ip(&state, inOut)
    for idx in 0..<15 {
      let t = state[1]
      let i = f(state[1], schedule[idx])
      state[1] = i ^ state[0]
      state[0] = t
    }
    state[0] = f(state[1], schedule[15]) ^ state[0]
    var out = inOut
    invIP(state, &out)
    inOut = out
  }

  private static func run(_ buf: inout [UInt8], key: [UInt8], length: Int, decrypt: Bool) {
    var schedule = Array(repeating: [0, 0, 0, 0, 0, 0], count: 16)
    desKeySetup(key, &schedule, decrypt: decrypt)
    var i = 0
    while i + 8 <= length {
      var block = Array(buf[i..<(i + 8)])
      desBlock(&block, schedule)
      for (j, v) in block.enumerated() { buf[i + j] = v }
      i += 8
    }
  }

  static func lyricDecode(_ buf: inout [UInt8]) {
    let n = buf.count
    run(&buf, key: key1, length: n, decrypt: true)
    run(&buf, key: key2, length: n, decrypt: false)
    run(&buf, key: key3, length: n, decrypt: true)
  }
}
