import Foundation
import Compression

// MARK: - 源脚本解析 + 压缩
// 完整复刻 src/main/modules/userApi/utils.ts:
//  parseScriptInfo / matchInfo / deflateScript / inflateScript / importApi 去重规则

enum SourceScriptError: LocalizedError {
  case invalidFile
  case tooLarge
  case duplicated(existingName: String)

  var errorDescription: String? {
    switch self {
    case .invalidFile: return "无效的自定义源文件（缺少头部 /* @name ... */ 块注释）"
    case .tooLarge: return "脚本过大（>9MB，拒绝导入）"
    case .duplicated(let n): return "导入失败，脚本内容与已有的源「\(n)」相同"
    }
  }
}

struct SourceScriptMeta {
  var name: String
  var description: String
  var author: String
  var homepage: String
  var version: String
}

struct SourceScriptParser {
  /// 解析首段 /* ... */ 块注释中的 @name/@description/@author/@homepage/@version
  /// rxp: /^\s?\*\s?@(\w+)\s(.+)$/  只认这5个key
  static func parseMeta(_ scriptRaw: String) throws -> SourceScriptMeta {
    guard let range = scriptRaw.range(of: #"\/\*[\s\S]+?\*\/"#, options: .regularExpression) else {
      throw SourceScriptError.invalidFile
    }
    let header = String(scriptRaw[range])
    var dict: [String: String] = [:]
    let rxp = try! NSRegularExpression(pattern: #"^\s?\*\s?@(\w+)\s(.+)$"#)
    for line in header.components(separatedBy: .newlines) {
      let ns = line as NSString
      if let m = rxp.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
         m.numberOfRanges == 3 {
        let k = ns.substring(with: m.range(at: 1))
        let v = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        if ["name", "description", "author", "homepage", "version"].contains(k) {
          dict[k] = v
        }
      }
    }
    func cut(_ v: String?, _ len: Int) -> String {
      let s = v ?? ""
      return s.count > len ? String(s.prefix(len)) + "..." : s
    }
    var name = cut(dict["name"], 24)
    if name.isEmpty { name = "user_api_\(Date().description)" }
    return SourceScriptMeta(
      name: name,
      description: cut(dict["description"], 36),
      author: cut(dict["author"], 56),
      homepage: cut(dict["homepage"], 1024),
      version: cut(dict["version"], 36)
    )
  }

  // MARK: zlib deflate/inflate (Treat as zlib-wrapped, 与 node zlib.deflate/inflate 对应)

  static func deflateToStorage(_ raw: String) throws -> String {
    guard let data = raw.data(using: .utf8) else { throw SourceScriptError.invalidFile }
    let compressed = try compress(data)
    return "gz_" + compressed.base64EncodedString()
  }

  static func inflateFromStorage(_ stored: String) throws -> String {
    guard stored.hasPrefix("gz_") else { return stored } // 兼容明文老数据
    guard let data = Data(base64Encoded: String(stored.dropFirst(3))) else {
      throw SourceScriptError.invalidFile
    }
    let out = try decompress(data)
    return String(data: out, encoding: .utf8) ?? ""
  }

  static func compress(_ data: Data) throws -> Data {
    data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
      let srcSize = src.count
      // 足够大的目的缓冲
      let dstCapacity = srcSize + srcSize / 10 + 64
      let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
      defer { dst.deallocate() }
      let written = compression_encode_buffer(
        dst, dstCapacity,
        src.bindMemory(to: UInt8.self).baseAddress!, srcSize,
        nil, COMPRESSION_ZLIB)
      guard written > 0 else { return Data() }
      return Data(bytes: dst, count: written)
    }
  }

  static func decompress(_ data: Data) throws -> Data {
    data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
      let capacity = max(src.count * 8, 1024 * 64)
      var output = Data()
      var tmp = [UInt8](repeating: 0, count: capacity)
      let written = tmp.withUnsafeMutableBytes { dst -> Int in
        compression_decode_buffer(
          dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
          src.bindMemory(to: UInt8.self).baseAddress!, src.count,
          nil, COMPRESSION_ZLIB)
      }
      guard written > 0 else { return Data() }
      output.append(contentsOf: tmp.prefix(written))
      return output
    }
  }
}
