import Foundation
@preconcurrency import Network

// MARK: - 开放 API 服务（对标 main/modules/openApi）
// 本机 HTTP 控制接口，默认端口 33030（设置页可改）。
// 播放控制：GET /status /play /pause /toggle /next /prev /lyric（当前播放歌词）
// 音源查询（any-listen 解析层直出，query 参数均已 percentDecode）：
//   GET /search?keyword=&source=kw|kg|tx|wy|mg&page=1&limit=20
//   GET /songlist/search?keyword=&source=wy|tx|kg&page=1&limit=20
//   GET /songlist/detail?source=&id=&page=1&limit=30
//   GET /board?source=                      （榜单目录 TopSongsItem）
//   GET /board/detail?source=&id=&page=1&limit=50
//   GET /lyric?source=&songmid=&hash=&secs=&name=   （按曲取词；无 source 时返回当前播放歌词）

final class OpenApiServer {
  private var listener: NWListener?
  private(set) var running = false
  var port: Int = UserDefaults.standard.integer(forKey: "openApi.port").nonZero ?? 33030

  /// 异步命令回调（查询路由需走网络）；params 为已解码 query 键值
  var onCommand: (@MainActor @Sendable (String, [String: String]) async -> String)?

  func start() {
    stop()
    guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
    let command = onCommand
    do {
      let l = try NWListener(using: .tcp, on: p)
      l.newConnectionHandler = { conn in
        Self.handle(conn, command: command)
      }
      l.start(queue: .global())
      listener = l
      running = true
    } catch { return }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    running = false
  }

  func setPort(_ p: Int) {
    port = p
    UserDefaults.standard.set(p, forKey: "openApi.port")
    if running { start() }
  }

  private static func handle(_ conn: NWConnection, command: (@MainActor @Sendable (String, [String: String]) async -> String)?) {
    conn.start(queue: .global())
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
      guard let data, let req = String(data: data, encoding: .utf8) else {
        conn.cancel()
        return
      }
      // 请求行：GET /path?query HTTP/1.1
      let requestLine = req.components(separatedBy: "\r\n").first ?? ""
      let target = requestLine.components(separatedBy: " ").dropFirst().first ?? "/"
      let path = target.components(separatedBy: "?").first ?? "/"
      var params: [String: String] = [:]
      if let qIdx = target.firstIndex(of: "?") {
        for pair in target[target.index(after: qIdx)...].components(separatedBy: "&") {
          let kv = pair.components(separatedBy: "=")
          guard let rawKey = kv.first, !rawKey.isEmpty else { continue }
          let key = rawKey.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawKey
          let rawVal = kv.count > 1 ? kv[1] : ""
          let val = rawVal.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawVal
          params[key] = val
        }
      }
      // 查询路由走 async（网络）；MainActor 求值后回写连接
      Task { @MainActor in
        let body = await command?(path, params) ?? "{\"ok\":false}"
        let resp = "HTTP/1.0 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        if !isComplete {
          conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in }
        }
      }
    }
  }
}

private extension Int {
  var nonZero: Int? { self == 0 ? nil : self }
}

extension String {
  /// 包成 JSON 字符串字面量
  var jsonEscaped: String {
    let d = try? JSONSerialization.data(withJSONObject: self)
    return String(data: d ?? Data(), encoding: .utf8) ?? "\"\""
  }
}

extension Dictionary where Key == String, Value == Any {
  /// 序列化为 JSON 对象文本（openApi 路由返回体）
  var jsonEncoded: String {
    let d = try? JSONSerialization.data(withJSONObject: self)
    return String(data: d ?? Data(), encoding: .utf8) ?? "{}"
  }
}

extension Array where Element == Any {
  var jsonEncoded: String {
    let d = try? JSONSerialization.data(withJSONObject: self)
    return String(data: d ?? Data(), encoding: .utf8) ?? "[]"
  }
}
