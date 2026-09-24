import Foundation
@preconcurrency import Network

// MARK: - 开放 API 服务（对标 main/modules/openApi）
// 本机 HTTP 控制接口，默认端口 33030（设置页可改）：
//   GET /status          -> {playing, mode, song:{name,singer,source,songmid}, progress}
//   GET /play /pause /toggle /next /prev
//   GET /lyric           -> 当前歌词全文
// 说明：桌面端 openApi 还支持换源/音质等更多动作，MVP 只保留播放控制子集。

final class OpenApiServer {
  private var listener: NWListener?
  private(set) var running = false
  var port: Int = UserDefaults.standard.integer(forKey: "openApi.port").nonZero ?? 33030

  var onCommand: (@MainActor @Sendable (String) -> String)? // 返回 JSON 字符串

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

  private static func handle(_ conn: NWConnection, command: (@MainActor @Sendable (String) -> String)?) {
    conn.start(queue: .global())
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
      guard let data, let req = String(data: data, encoding: .utf8) else {
        conn.cancel()
        return
      }
      let path = req.components(separatedBy: " ").dropFirst().first?.components(separatedBy: "?").first ?? "/"
      let body: String = DispatchQueue.main.sync {
        command?(path) ?? "{\"ok\":false}"
      }
      let resp = "HTTP/1.0 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
      if !isComplete {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in }
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