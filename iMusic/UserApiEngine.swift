import Foundation
import Observation
@preconcurrency import JavaScriptCore
import CryptoKit
import CommonCrypto
import Compression

// MARK: - UserApiEngine（JS 沙箱）
// 复刻 src/main/modules/userApi/renderer/preload.js + main.ts createWindow/initEnv
// 原项目：独立隐藏 BrowserWindow + contextBridge lx + needle + crypto + 20s超时 + 响应校验
// 本项目：JavaScriptCore JSContext（无DOM，脚本仅需 lx.* 即可运行；
//        若某源脚本依赖 document/window 会初始化失败并上报，与原项目 webFrame 错误上报对齐）

@Observable @MainActor
final class UserApiEngine {
  /// 是否有任意脚本成功初始化（UI 据此判断是否走自定义源）
  var inited = false
  var message = "未加载"
  /// 按优先级聚合后的能力表：靠前脚本先声明的 action/quality 优先
  var sources: [String: UserApiSourceInfo] = [:]
  var qualitys: [String: [MusicQuality]] = [:]

  /// 有序脚本上下文（数组顺序 = 优先级，对标 config.ts enabledScripts 勾选顺序）
  private var scripts: [ScriptContext] = []

  /// 代理（对标 setting network.proxy + preload getRequestAgent；host 为空即直连）
  fileprivate var netSession: URLSession = .shared

  func applyProxy(host: String, port: Int) {
    UserDefaults.standard.set(host, forKey: "proxy.host")
    UserDefaults.standard.set(port, forKey: "proxy.port")
    guard !host.isEmpty, port > 0 else { netSession = .shared; return }
    let c = URLSessionConfiguration.default
    c.connectionProxyDictionary = ["HTTPEnable": true, "HTTPProxy": host, "HTTPPort": port,
                                   "HTTPSEnable": true, "HTTPSProxy": host, "HTTPSPort": port]
    netSession = URLSession(configuration: c)
  }

  func loadProxy() {
    applyProxy(host: UserDefaults.standard.string(forKey: "proxy.host") ?? "",
               port: UserDefaults.standard.integer(forKey: "proxy.port"))
  }

  var onUpdateAlert: ((UpdateAlert) -> Void)?

  /// 音质降级链（低 -> 高），对齐 isolate/index.ts:141 的 `types`（全部 8 档）
  static let qualityLadder: [MusicQuality] = [
    .q128k, .q192k, .q320k, .wav, .flac, .flac24bit, .dolby, .master,
  ]

  // MARK: - 可选代理 URL 包装（对齐 onlineResource/index.ts:5-12 的 musicUtils.createProxyUrl）

  /// 代理基址。默认 nil = 关闭（不强制包装），设置后 musicUrl 结果会经 `createProxyURL` 包装。
  /// 本类为 @MainActor，静态存储属性继承 MainActor 隔离，无跨线程数据竞争（非 Sendable 全局）。
  static var proxyBaseURL: String? = nil

  /// setter：传入 nil / 空字符串即恢复默认关闭。
  static func setProxyBaseURL(_ base: String?) {
    proxyBaseURL = base
  }

  /// 对标 any-listen proxyServer.createProxy + buildVirtualPublicPath：
  /// 结果形如 `<base>/<sha256(url)><ext>`（base 以 '/' 开头时加 `al-ps-host:` 前缀）。
  /// 未配置代理、或非 http(s) URL 时原样返回（行为可用但不强制开启）。
  static func createProxyURL(_ raw: String) -> String {
    guard let base = proxyBaseURL, !base.isEmpty,
          let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return raw }
    let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
    let name = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined() + ext
    let prefix = base.hasPrefix("/") ? "al-ps-host:" : ""
    let sep = base.hasSuffix("/") ? "" : "/"
    return prefix + base + sep + name
  }

  struct ScriptSpec {
    var id: String
    var scriptRaw: String
    var meta: SourceScriptMeta
  }

  // MARK: - load / unload

  /// 按序加载全部启用脚本（src/main/index.ts:9-38）。
  /// 单个脚本失败不阻断其他脚本；能力按脚本优先级聚合。
  func loadAll(_ specs: [ScriptSpec]) async {
    unload()
    guard !specs.isEmpty else {
      message = "当前为内置模式（无启用自定义源）"
      aggregate()
      return
    }
    var loaded: [ScriptContext] = []
    var failures: [String] = []
    for spec in specs {
      let context = ScriptContext(id: spec.id, owner: self, meta: spec.meta, rawScript: spec.scriptRaw)
      do {
        try await context.load()
        loaded.append(context)
      } catch {
        failures.append("\(spec.meta.name)：\(error.localizedDescription)")
        context.unload()
      }
    }
    scripts = loaded
    aggregate()
    inited = !loaded.isEmpty
    if loaded.isEmpty {
      message = "源加载失败：\(failures.prefix(2).joined(separator: "；"))"
    } else {
      message = "已加载 \(loaded.count) 个源：\(loaded.map(\.message).joined(separator: "；"))"
        + (failures.isEmpty ? "" : "（另有 \(failures.count) 个失败）")
    }
  }

  func unload() {
    for context in scripts { context.unload() }
    scripts.removeAll()
    inited = false
    sources = [:]
    qualitys = [:]
  }

  /// 单个脚本初始化后声明的能力（供 AppState 回写 UserApiInfo.sources）
  func sources(forScript id: String) -> [String: UserApiSourceInfo] {
    scripts.first { $0.id == id }?.sources ?? [:]
  }

  /// 按优先级合并各脚本声明的 source -> actions/qualitys（相同项靠前者胜）
  private func aggregate() {
    var acts: [String: [UserApiAction]] = [:]
    var quals: [String: [MusicQuality]] = [:]
    for script in scripts where script.inited {
      for (source, info) in script.sources {
        var a = acts[source] ?? []
        for action in info.actions where !a.contains(action) { a.append(action) }
        acts[source] = a
        var q = quals[source] ?? []
        for quality in info.qualitys where !q.contains(quality) { q.append(quality) }
        quals[source] = q
      }
    }
    var merged: [String: UserApiSourceInfo] = [:]
    for (source, actions) in acts {
      merged[source] = UserApiSourceInfo(type: "music", actions: actions, qualitys: quals[source] ?? [])
    }
    sources = merged
    qualitys = merged.mapValues { $0.qualitys }
  }

  // MARK: - 多脚本调度（isolate/index.ts:141-167）

  /// 按优先级找能处理该 source+action+quality 的脚本；musicUrl 沿降级链逐级向下找。
  private func findTarget(source: String, action: UserApiAction, quality: MusicQuality,
                          excludeIDs: [String]) -> (script: ScriptContext, quality: MusicQuality)? {
    let candidates = scripts.filter { $0.inited && !excludeIDs.contains($0.id) }
    // lyric/pic 与音质无关：取首个声明该 source+action 的脚本
    if action != .musicUrl {
      guard let s = candidates.first(where: { $0.sources[source]?.actions.contains(action) == true }) else { return nil }
      return (s, quality)
    }
    let start = Self.qualityLadder.firstIndex(of: quality) ?? Self.qualityLadder.count - 1
    for index in stride(from: start, through: 0, by: -1) {
      let q = Self.qualityLadder[index]
      if let s = candidates.first(where: {
        guard let info = $0.sources[source] else { return false }
        return info.actions.contains(.musicUrl) && info.qualitys.contains(q)
      }) {
        return (s, q)
      }
    }
    return nil
  }

  /// 统一入口：优先级 + 音质降级 + 失败 exclude 递归（对标 getMusicUrl）。
  func callScript(source: String, action: UserApiAction, quality: MusicQuality,
                  music: MusicInfo) async throws -> Any {
    try await callScript(source: source, action: action, quality: quality, music: music, excludeIDs: [])
  }

  private func callScript(source: String, action: UserApiAction, quality: MusicQuality,
                          music: MusicInfo, excludeIDs: [String]) async throws -> Any {
    guard let target = findTarget(source: source, action: action, quality: quality, excludeIDs: excludeIDs) else {
      throw NSError(domain: "LX", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "没有可用源处理 \(source)/\(action.rawValue)（\(quality.rawValue)）"])
    }
    do {
      let value = try await target.script.call(source: source, action: action, quality: target.quality, music: music)
      if action == .musicUrl, let url = value as? String {
        // shared/utils.ts:43-56 verifyUrl：Range: bytes=0-1 校验可达性并返回最终重定向 URL
        let verified = try await verifyURL(url)
        // onlineResource/index.ts:10 musicUtils.createProxyUrl(url, {}, enabledCache)
        return Self.createProxyURL(verified)
      }
      return value
    } catch {
      // 失败脚本加入排除表，从原始请求音质重新选源（对齐 isolate/index.ts:165）
      guard !excludeIDs.contains(target.script.id) else { throw error }
      return try await callScript(source: source, action: action, quality: quality, music: music,
                                  excludeIDs: excludeIDs + [target.script.id])
    }
  }

  /// verifyUrl（shared/utils.ts:43-56）：GET + `Range: bytes=0-1`，跟随重定向，
  /// 要求 2xx，返回最终 URL（`resp.history[resp.history.length - 1]`）。
  private func verifyURL(_ raw: String) async throws -> String {
    guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      throw NSError(domain: "LX", code: -5, userInfo: [NSLocalizedDescriptionKey: "源返回了非法URL"])
    }
    let probe = URLRangeProbe()
    return try await probe.finalURL(for: url)
  }
}

// MARK: - 单脚本 JSContext（沙箱隔离：每脚本独立 lx/console/全局变量）
@MainActor
private final class ScriptContext {
  let id: String
  let meta: SourceScriptMeta
  let rawScript: String
  /// 弱引用宿主，共享代理会话与更新提示回调
  unowned let owner: UserApiEngine

  var inited = false
  var message = "未加载"
  var sources: [String: UserApiSourceInfo] = [:]
  var qualitys: [String: [MusicQuality]] = [:]

  private var ctx: JSContext?
  private var requestHandler: JSValue?
  private var pending: [String: CheckedContinuation<JSValue, Error>] = [:]
  private var tasks: [String: URLSessionDataTask] = [:]
  private var generation = 0
  private var initedContinuation: CheckedContinuation<Void, Error>?

  private func lxError(_ code: Int, _ msg: String) -> NSError {
    NSError(domain: "LX", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
  }

  /// 与 preload.js 一致的过滤表。注意：lyric/pic 同样允许在线源声明
  /// （修复旧实现仅 local 可声明 lyric/pic，导致脚本歌词/封面永远不执行的缺陷）。
  private let allSources = ["kw", "kg", "tx", "wy", "mg", "local"]
  private let supportQualitys: [String: [String]] = [
    "kw": ["128k", "320k", "flac", "flac24bit"],
    "kg": ["128k", "320k", "flac", "flac24bit"],
    "tx": ["128k", "320k", "flac", "flac24bit"],
    "wy": ["128k", "320k", "flac", "flac24bit"],
    "mg": ["128k", "320k", "flac", "flac24bit"],
    "local": [],
  ]
  private let supportActions: [String: [String]] = [
    "kw": ["musicUrl", "lyric", "pic"], "kg": ["musicUrl", "lyric", "pic"],
    "tx": ["musicUrl", "lyric", "pic"], "wy": ["musicUrl", "lyric", "pic"],
    "mg": ["musicUrl", "lyric", "pic"], "xm": ["musicUrl", "lyric", "pic"],
    "local": ["musicUrl", "lyric", "pic"],
  ]

  init(id: String, owner: UserApiEngine, meta: SourceScriptMeta, rawScript: String) {
    self.id = id
    self.owner = owner
    self.meta = meta
    self.rawScript = rawScript
  }

  // MARK: load
  /// 取走并 resume 初始化 continuation（防 double-resume / 泄漏）
  private func resumeInited(_ result: Result<Void, Error>) {
    guard let c = initedContinuation else { return }
    initedContinuation = nil
    c.resume(with: result)
  }

  /// 取走并 resume 全部 callScript continuation
  private func resumeAllPending(_ error: Error) {
    let all = pending
    pending.removeAll()
    for (_, c) in all { c.resume(throwing: error) }
  }

  /// 加载并执行源脚本，等待其调用 lx.send('inited', {sources})，复刻 initEnv + handleInit
  func load() async throws {
    let gen = generation
    message = "源初始化中…"
    inited = false; sources = [:]

    let ctx = JSContext()!
    self.ctx = ctx
    ctx.exceptionHandler = { [weak self] _, ex in
      guard let self else { return }
      let msg = ex?.toString() ?? "unknown"
      Task { @MainActor in
        guard self.generation == gen, !self.inited else { return }
        self.message = "源初始化失败：\(msg.prefix(200))".description
        self.resumeInited(.failure(self.lxError(-1, String(msg.prefix(500)))))
      }
    }
    // console.log 兜底（部分脚本会打印日志）
    let log: @convention(block) (JSValue) -> Void = { v in print("[userscript]", v.toString() ?? "") }
    ctx.setObject(log, forKeyedSubscript: "print" as NSString)
    ctx.evaluateScript("var console = {log: print, warn: print, error: print}; var window = this; var globalThis = this;")
    // 初始化期错误上报（对标 preload webFrame error/unhandledrejection -> sendError）
    let initErr: @convention(block) (JSValue) -> Void = { [weak self] e in
      guard let self else { return }
      let msg = e.toString() ?? "unknown"
      Task { @MainActor in
        guard self.generation == gen, !self.inited else { return }
        self.message = "源初始化失败：\(msg.prefix(200))"
        self.resumeInited(.failure(self.lxError(-1, String(msg.prefix(500)))))
      }
    }
    ctx.setObject(initErr, forKeyedSubscript: "__lx_init_error" as NSString)

    injectLx(into: ctx, generation: gen)

    // 等待脚本调用 send('inited')
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      initedContinuation = cont
      // 超时 20s（对齐 rendererEvent 20s cancel）；只 resume 自己这一代
      DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
        Task { @MainActor in
          guard let self, self.generation == gen, !self.inited else { return }
          self.resumeInited(.failure(self.lxError(-1, "源初始化超时（20s，未调用 lx.send('inited')）")))
        }
      }
      ctx.evaluateScript(wrapped(rawScript))
    }
  }

  /// JavaScriptCore 的 evaluateScript 不支持顶层 await（实测报 SyntaxError），
  /// 而真实源脚本大量使用顶层 `await lx.send(...)`，故用 async IIFE 包裹执行。
  /// 包裹后脚本仍只能通过 lx 与宿主通信，语义与桌面端一致。
  private func wrapped(_ script: String) -> String {
    ";(async()=>{\n" + script + "\n})().catch(e=>{ try{__lx_init_error(e&&e.message||String(e))}catch(_){} });"
  }

  func unload() {
    generation += 1
    for (_, t) in tasks { t.cancel() }
    tasks.removeAll()
    let cancelErr = lxError(-7, "源已卸载")
    resumeAllPending(cancelErr)
    resumeInited(.failure(cancelErr))
    requestHandler = nil; ctx = nil
    inited = false; sources = [:]
  }

  // MARK: - lx 注入
  private func injectLx(into ctx: JSContext, generation gen: Int) {
    guard let lx = JSValue(newObjectIn: ctx) else { return }
    ctx.setObject(lx, forKeyedSubscript: "lx" as NSString)

    // EVENT_NAMES（文档要求 globalThis.lx.EVENT_NAMES，脚本普遍 const { EVENT_NAMES, request, on, send } = globalThis.lx）
    if let names = JSValue(newObjectIn: ctx) {
      names.setObject("request", forKeyedSubscript: "request" as NSString)
      names.setObject("inited", forKeyedSubscript: "inited" as NSString)
      names.setObject("updateAlert", forKeyedSubscript: "updateAlert" as NSString)
      lx.setObject(names, forKeyedSubscript: "EVENT_NAMES" as NSString)
    }

    // ---- lx.request(url, opts, callback) ----
    // 对标 preload needle：method/headers/body/form/formData/timeout(<=60s)/JSON尝试解析/返回cancel函数
    let requestBlock: @convention(block) (String, JSValue, JSValue) -> JSValue = { [weak self] url, opts, callback in
      guard let self, self.generation == gen, self.ctx != nil,
            let url0 = URL(string: url) else { return JSValue(undefinedIn: JSContext.current()) }
      let method = opts.forProperty("method")?.toString() ?? "get"
      var timeout: TimeInterval = 60
      if let t = opts.forProperty("timeout")?.toNumber(), t.doubleValue > 0 {
        timeout = min(t.doubleValue / 1000.0, 60)
      }
      var req = URLRequest(url: url0, timeoutInterval: timeout)
      req.httpMethod = method.uppercased()
      // headers 值可能是数字等非字符串，统一 stringify（桌面端 needle 同理透传）
      if let h = opts.forProperty("headers")?.toDictionary() as? [String: Any] {
        for (k, v) in h { req.setValue("\(v)", forHTTPHeaderField: k) }
      }
      let bodyVal = opts.forProperty("body")
      if let b = bodyVal, !b.isUndefined && !b.isNull {
        if b.isString {
          let s = b.toString() ?? ""
          if !s.isEmpty && s != "undefined" { req.httpBody = s.data(using: .utf8) }
        } else if let obj = b.toObject() {
          // body 传对象时按 JSON 发送
          req.httpBody = try? JSONSerialization.data(withJSONObject: obj)
          if req.value(forHTTPHeaderField: "Content-Type") == nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
          }
        }
      } else if let form = opts.forProperty("form")?.toDictionary() as? [String: Any] {
        let s = form.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)=\("\($0.value)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }.joined(separator: "&")
        req.httpBody = s.data(using: .utf8)
        if req.value(forHTTPHeaderField: "Content-Type") == nil {
          req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
      } else if let fd = opts.forProperty("formData")?.toDictionary() as? [String: Any] {
        // multipart/form-data（桌面端 needle 透传；此处手动组装 boundary）
        let boundary = "LXBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        for (k, v) in fd {
          body.append("--\(boundary)\r\n".data(using: .utf8)!)
          body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
          body.append("\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      }
      let key = UUID().uuidString
      let task = self.owner.netSession.dataTask(with: req) { data, resp, err in
        Task { @MainActor in
          self.tasks.removeValue(forKey: key)
          // 代际已变/上下文已卸载：丢弃回调，避免旧 JSValue 打进已释放的 JSContext
          guard self.generation == gen, self.ctx != nil else { return }
          let http = resp as? HTTPURLResponse
          if let err {
            callback.call(withArguments: [err.localizedDescription, JSValue(nullIn: ctx) as Any, JSValue(nullIn: ctx) as Any])
            return
          }
          let bodyStr = String(data: data ?? Data(), encoding: .utf8) ?? ""
          // 尝试 JSON 解析后回传（对齐 resp.body JSON.parse）
          var bodyVal: Any = bodyStr
          if let d = bodyStr.data(using: .utf8),
             let j = try? JSONSerialization.jsonObject(with: d) {
            bodyVal = j
          }
          let respObj: [String: Any] = [
            "statusCode": http?.statusCode ?? 200,
            "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 200),
            "headers": http?.allHeaderFields as? [String: String] ?? [:],
            "body": bodyVal,
          ]
          callback.call(withArguments: [JSValue(nullIn: ctx) as Any, respObj, bodyVal])
        }
      }
      self.tasks[key] = task
      task.resume()
      let cancel: @convention(block) () -> Void = { [weak self] in
        Task { @MainActor in self?.tasks[key]?.cancel() }
      }
      return JSValue(object: cancel, in: JSContext.current() ?? ctx)!
    }
    lx.setObject(requestBlock, forKeyedSubscript: "request" as NSString)

    // ---- lx.send(event, data) ---- await 非Promise亦可，故同步返回即可
    let sendBlock: @convention(block) (String, JSValue) -> Bool = { [weak self] event, data in
      guard let self, self.generation == gen else { return false }
      switch event {
      case "inited":
        self.handleInited(data)
        return true
      case "updateAlert":
        let log = data.forProperty("log")?.toString() ?? ""
        let url = data.forProperty("updateUrl")?.toString()
        let clean = (url?.hasPrefix("http") == true) ? (url == "undefined" ? nil : url) : nil
        let alert = UpdateAlert(name: self.meta.name, log: String(log.prefix(1024)), updateUrl: clean)
        self.owner.onUpdateAlert?(alert)
        return true
      default:
        return false
      }
    }
    lx.setObject(sendBlock, forKeyedSubscript: "send" as NSString)

    // ---- lx.on('request', handler) ----
    let onBlock: @convention(block) (String, JSValue) -> Bool = { [weak self] event, handler in
      guard let self, self.generation == gen, event == "request" else { return false }
      self.requestHandler = handler
      // 绑定 userApi_request 监听（此时才开始接受宿主请求，对齐 preload handleInit 后 ipcRenderer.on(request)）
      return true
    }
    lx.setObject(onBlock, forKeyedSubscript: "on" as NSString)

    lx.setObject("2.0.0", forKeyedSubscript: "version" as NSString)
    lx.setObject("desktop", forKeyedSubscript: "env" as NSString)
    if let info = JSValue(newObjectIn: ctx) {
      info.setObject(meta.name, forKeyedSubscript: "name" as NSString)
      info.setObject(meta.description, forKeyedSubscript: "description" as NSString)
      info.setObject(meta.version, forKeyedSubscript: "version" as NSString)
      info.setObject(meta.author, forKeyedSubscript: "author" as NSString)
      info.setObject(meta.homepage, forKeyedSubscript: "homepage" as NSString)
      info.setObject(rawScript.prefix(200_000).description, forKeyedSubscript: "rawScript" as NSString)
      lx.setObject(info, forKeyedSubscript: "currentScriptInfo" as NSString)
    }

    // ---- lx.utils ----
    guard let utils = JSValue(newObjectIn: ctx),
          let crypto = JSValue(newObjectIn: ctx),
          let buffer = JSValue(newObjectIn: ctx),
          let zlib = JSValue(newObjectIn: ctx) else { return }
    lx.setObject(utils, forKeyedSubscript: "utils" as NSString)
    utils.setObject(crypto, forKeyedSubscript: "crypto" as NSString)
    utils.setObject(buffer, forKeyedSubscript: "buffer" as NSString)
    utils.setObject(zlib, forKeyedSubscript: "zlib" as NSString)

    let md5: @convention(block) (String) -> String = { s in
      Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    crypto.setObject(md5, forKeyedSubscript: "md5" as NSString)

    let rand: @convention(block) (Int) -> JSValue = { [weak self] size in
      var b = [UInt8](repeating: 0, count: max(0, min(size, 1024)))
      _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
      guard let c = self?.ctx else { return JSValue(undefinedIn: JSContext.current()) }
      return JSValue(object: b.map { Int($0) }, in: c)!
    }
    crypto.setObject(rand, forKeyedSubscript: "randomBytes" as NSString)

    // aesEncrypt(buffer(Uint8Array/Array/base64), mode, key, iv) -> Array<Int>
    let aes: @convention(block) (JSValue, String, JSValue, JSValue) -> JSValue = { buf, mode, key, iv in
      let c = JSContext.current()!
      do {
        let data = Self.jsToBytes(buf)
        let k = Self.jsToBytes(key)
        let v = Self.jsToBytes(iv)
        let out = try Self.aesEncrypt(data: data, mode: mode, key: k, iv: v)
        return JSValue(object: out.map { Int($0) }, in: c)!
      } catch {
        c.exception = JSValue(newErrorFromMessage: "aesEncrypt: \(error.localizedDescription)", in: c)
        return JSValue(undefinedIn: c)
      }
    }
    crypto.setObject(aes, forKeyedSubscript: "aesEncrypt" as NSString)

    // rsaEncrypt：原项目 RSA_NO_PADDING（左补0到128字节）。原生大数实现（Security 不依赖）。
    let rsa: @convention(block) (JSValue, String) -> JSValue = { buf, pemKey in
      let c = JSContext.current()!
      do {
        let data = Self.jsToBytes(buf)
        let out = try Self.rsaEncrypt(data: data, pemKey: pemKey)
        return JSValue(object: out.map { Int($0) }, in: c)!
      } catch {
        c.exception = JSValue(newErrorFromMessage: "rsaEncrypt: \(error.localizedDescription)", in: c)
        return JSValue(undefinedIn: c)
      }
    }
    crypto.setObject(rsa, forKeyedSubscript: "rsaEncrypt" as NSString)

    // buffer.from(...) -> Array<Int>；bufToString(buf, format)
    let from: @convention(block) (JSValue, JSValue) -> JSValue = { val, enc in
      let c = JSContext.current()!
      if val.isString {
        let s = val.toString() ?? ""
        let e = enc.isUndefined ? "utf8" : (enc.toString() ?? "utf8")
        let d: Data
        switch e {
        case "hex": d = Self.hexToData(s)
        case "base64": d = Data(base64Encoded: s) ?? Data()
        default: d = Data(s.utf8)
        }
        return JSValue(object: [UInt8](d).map { Int($0) }, in: c)!
      }
      if val.isArray || val.isObject {
        return val // 已是字节数组则透传
      }
      return JSValue(object: [], in: c)!
    }
    buffer.setObject(from, forKeyedSubscript: "from" as NSString)
    let toStr: @convention(block) (JSValue, JSValue) -> String = { val, fmt in
      let bytes = Self.jsToBytes(val)
      switch (fmt.isUndefined ? "utf8" : (fmt.toString() ?? "utf8")) {
      case "hex": return bytes.map { String(format: "%02x", $0) }.joined()
      case "base64": return Data(bytes).base64EncodedString()
      default: return String(data: Data(bytes), encoding: .utf8) ?? ""
      }
    }
    buffer.setObject(toStr, forKeyedSubscript: "bufToString" as NSString)

    // zlib：MVP同步实现（await 同步值亦可）
    let inflate: @convention(block) (JSValue) -> JSValue = { val in
      let c = JSContext.current()!
      let bytes = Self.jsToBytes(val)
      if let out = try? SourceScriptParser.decompress(Data(bytes)) {
        return JSValue(object: [UInt8](out).map { Int($0) }, in: c)!
      }
      return JSValue(undefinedIn: c)
    }
    let deflate: @convention(block) (JSValue) -> JSValue = { val in
      let c = JSContext.current()!
      let bytes = Self.jsToBytes(val)
      if let out = try? SourceScriptParser.compress(Data(bytes)) {
        return JSValue(object: [UInt8](out).map { Int($0) }, in: c)!
      }
      return JSValue(undefinedIn: c)
    }
    zlib.setObject(inflate, forKeyedSubscript: "inflate" as NSString)
    zlib.setObject(deflate, forKeyedSubscript: "deflate" as NSString)
  }

  // MARK: - handleInited（复刻 preload handleInit 交集过滤）
  private func handleInited(_ data: JSValue) {
    var out: [String: UserApiSourceInfo] = [:]
    let srcs = data.forProperty("sources")
    for s in allSources {
      let u = srcs?.forProperty(s)
      guard u != nil && !u!.isUndefined,
            u?.forProperty("type")?.toString() == "music" else { continue }
      let ua = (u?.forProperty("actions")?.toArray() as? [String]) ?? []
      let uq = (u?.forProperty("qualitys")?.toArray() as? [String]) ?? []
      let actions = (supportActions[s] ?? []).filter { ua.contains($0) }.compactMap(UserApiAction.init(rawValue:))
      let quals = (supportQualitys[s] ?? []).filter { uq.contains($0) }.compactMap(MusicQuality.init(rawValue:))
      out[s] = UserApiSourceInfo(type: "music", actions: actions, qualitys: quals)
    }
    self.sources = out
    self.qualitys = Dictionary(uniqueKeysWithValues: out.map { ($0.key, $0.value.qualitys) })
    self.inited = true
    self.message = "源已就绪：\(out.keys.sorted().joined(separator: ","))"
    resumeInited(.success(()))
  }

  // MARK: - 宿主 -> 本脚本 request（复刻 handleRequest + 20s超时 + 响应校验）
  /// - returns: musicUrl->URL字符串；pic->URL字符串；lyric->LyricInfo
  func call(source: String, action: UserApiAction, quality: MusicQuality, music: MusicInfo) async throws -> Any {
    guard let ctx, let handler = requestHandler else { throw lxError(-2, "源未初始化（request handler 缺失）") }
    let gen = generation
    let payload: [String: Any] = [
      "source": source,
      "action": action.rawValue,
      "info": [
        "type": quality.rawValue,
        "musicInfo": musicInfoJS(music),
      ],
    ]
    let promise: JSValue = handler.call(withArguments: [payload]) ?? JSValue(undefinedIn: ctx)
    let id = UUID().uuidString
    let oid = id.replacingOccurrences(of: "-", with: "_")
    let result: JSValue = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSValue, Error>) in
      pending[id] = cont
      let ok: @convention(block) (JSValue) -> Void = { [weak self] v in
        guard let self else { return }
        Task { @MainActor in
          if let c = self.pending.removeValue(forKey: id) { c.resume(returning: v) }
        }
      }
      let fail: @convention(block) (JSValue) -> Void = { [weak self] e in
        guard let self else { return }
        // 提取脚本错误：message 为主；仅当错误对象显式携带 code/data 字段时附加
        // （普通 new Error 无这些字段，stack 对混淆脚本是乱码且无诊断价值，不透出）
        let msg = e.toString() ?? "script error"
        var fullMsg = msg
        if let codeV = e.forProperty("code"), !codeV.isUndefined, !codeV.isNull,
           codeV.toInt32() != 0 {
          fullMsg = "[code:\(codeV.toInt32())] \(fullMsg)"
        }
        if let dataV = e.forProperty("data"), !dataV.isUndefined, !dataV.isNull,
           dataV.isString, let d = dataV.toString(), !d.isEmpty {
          fullMsg += " | data: \(d)"
        }
        Task { @MainActor in
          if let c = self.pending.removeValue(forKey: id) {
            c.resume(throwing: self.lxError(-3, fullMsg))
          }
        }
      }
      ctx.setObject(ok, forKeyedSubscript: "__ok_\(oid)" as NSString)
      ctx.setObject(fail, forKeyedSubscript: "__fail_\(oid)" as NSString)
      // promise.then(ok, fail)；兼容同步返回值（非Promise则直接 resolve）
      ctx.evaluateScript("""
        (function(p){ if (p && typeof p.then === 'function') { p.then(__ok_\(oid), __fail_\(oid)); } else { __ok_\(oid)(p); } })
        """)?.call(withArguments: [promise as Any])
      // 20s 超时（对齐主进程 requestQueue）；卸载时由 resumeAllPending 提前结束
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(20))
        Task { @MainActor [weak self] in
          guard let self, self.generation == gen,
                let c = self.pending.removeValue(forKey: id) else { return }
          c.resume(throwing: self.lxError(-4, "源请求超时（20s）"))
        }
      }
    } as JSValue
    // 清理一次性 JS 全局，避免脚本堆泄漏
    if generation == gen {
      ctx.setObject(nil, forKeyedSubscript: "__ok_\(oid)" as NSString)
      ctx.setObject(nil, forKeyedSubscript: "__fail_\(oid)" as NSString)
    }

    // ---- 响应校验（复刻 preload handleRequest）----
    switch action {
    case .musicUrl, .pic:
      guard let s = result.toString(), s.hasPrefix("http"), s.count <= 2048 else {
        throw NSError(domain: "LX", code: -5, userInfo: [NSLocalizedDescriptionKey: "源返回了非法URL"])
      }
      return s
    case .lyric:
      guard result.isObject, let l = result.forProperty("lyric")?.toString() else {
        throw NSError(domain: "LX", code: -5, userInfo: [NSLocalizedDescriptionKey: "源返回了非法歌词"])
      }
      guard l.count <= 51_200 else { throw NSError(domain: "LX", code: -5, userInfo: [NSLocalizedDescriptionKey: "歌词过长"]) }
      func pick(_ k: String, _ max: Int) -> String? {
        guard let v = result.forProperty(k)?.toString(), v != "undefined", !v.isEmpty, v.count < max else { return nil }
        return v
      }
      return LyricInfo(lyric: l, tlyric: pick("tlyric", 5120), rlyric: pick("rlyric", 5120), lxlyric: pick("lxlyric", 8192))
    }
  }

  private func musicInfoJS(_ m: MusicInfo) -> [String: Any] {
    // 传递给脚本的 musicInfo：尽量贴近原项目 MusicInfo 形状（name/singer/source/songmid/albumName/interval/types）
    ["name": m.name, "singer": m.singer, "source": m.source.rawValue,
     "songmid": m.songmid, "albumName": m.albumName, "interval": m.interval ?? "",
     "types": m.qualitys.map { ["type": $0.type.rawValue, "size": $0.size ?? ""] }]
  }

  // MARK: - helpers
  static func jsToBytes(_ v: JSValue?) -> [UInt8] {
    guard let v else { return [] }
    if v.isString {
      let s = v.toString() ?? ""
      // 可能是 hex/base64/utf8，优先按 utf8；hex 串特征由调用方保证经 buffer.from 转换
      return [UInt8](Data(s.utf8))
    }
    if let arr = v.toArray() {
      return arr.compactMap {
        if let n = $0 as? Int { return UInt8(clamping: n) }
        if let n = $0 as? Double { return UInt8(clamping: Int(n)) }
        if let n = $0 as? NSNumber { return UInt8(clamping: n.intValue) }
        return nil
      }
    }
    return []
  }

  static func hexToData(_ s: String) -> Data {
    var d = Data(); var hex = s
    while hex.count >= 2 { d.append(UInt8(hex.prefix(2), radix: 16) ?? 0); hex = String(hex.dropFirst(2)) }
    return d
  }

  static func aesEncrypt(data: [UInt8], mode: String, key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
    let m = mode.lowercased()
    let keyLen = (m.contains("256") || key.count > 16) ? kCCKeySizeAES256 : kCCKeySizeAES128
    var keyPadded = key
    if keyPadded.count < keyLen { keyPadded += [UInt8](repeating: 0, count: keyLen - keyPadded.count) }
    else { keyPadded = Array(keyPadded.prefix(keyLen)) }
    var ivPadded = iv
    if ivPadded.count < kCCBlockSizeAES128 { ivPadded += [UInt8](repeating: 0, count: kCCBlockSizeAES128 - ivPadded.count) }
    ivPadded = Array(ivPadded.prefix(kCCBlockSizeAES128))

    // CBC / ECB 走 CommonCrypto
    if m.contains("ecb") {
      return try cccrypt(data: data, key: keyPadded, keyLen: keyLen, iv: nil, options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode))
    }
    if m.contains("cbc") {
      return try cccrypt(data: data, key: keyPadded, keyLen: keyLen, iv: ivPadded, options: CCOptions(kCCOptionPKCS7Padding))
    }

    // CFB / CTR / OFB：用原始 AES 块原语手动实现（对齐 extensions/lx-api-source-loader 的 utils.crypto）
    let block = keyPadded
    if m.contains("ctr") {
      // aes-js CTR：initial counter = iv(16B)，大端自增，XOR 密钥流
      var counter = ivPadded
      var out = [UInt8](repeating: 0, count: data.count)
      for i in 0..<data.count {
        if i % 16 == 0 {
          let ks = aesBlockEncrypt(counter, key: block)
          for j in 0..<16 { if i + j < data.count { out[i + j] = data[i + j] ^ ks[j] } }
          incrementCounter(&counter)
        }
      }
      return out
    }
    if m.contains("ofb") {
      // aes-js OFB：AES(prev) 作密钥流（prev 初值 = iv）
      var prev = ivPadded
      var out = [UInt8](repeating: 0, count: data.count)
      for i in 0..<data.count {
        if i % 16 == 0 { prev = aesBlockEncrypt(prev, key: block) }
        out[i] = data[i] ^ prev[i % 16]
      }
      return out
    }
    if m.contains("cfb") {
      // aes-128-cfb：segment size = 16（整块）；shift register 初值 = iv
      var sr = ivPadded
      var out = [UInt8](repeating: 0, count: data.count)
      var i = 0
      while i < data.count {
        let ks = aesBlockEncrypt(sr, key: block)
        for j in 0..<16 where i + j < data.count {
          out[i + j] = data[i + j] ^ ks[j]
        }
        // shift register = 加密输出整块（非最后一整块时补零截断）
        for j in 0..<16 { sr[j] = (i + j < data.count) ? out[i + j] : 0 }
        i += 16
      }
      return out
    }
    // 兜底：无后缀的 cbc（lx 部分脚本直接给 "cbc"）
    return try cccrypt(data: data, key: keyPadded, keyLen: keyLen, iv: ivPadded, options: CCOptions(kCCOptionPKCS7Padding))
  }

  /// CommonCrypto 单次 AES 加解密（CBC/ECB + PKCS7）
  private static func cccrypt(data: [UInt8], key: [UInt8], keyLen: Int, iv: [UInt8]?, options: CCOptions) throws -> [UInt8] {
    let outCapacity = data.count + kCCBlockSizeAES128
    let outPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: outCapacity)
    defer { outPtr.deallocate() }
    var outLen: size_t = 0
    let status: CCCryptorStatus
    if let iv {
      status = key.withUnsafeBytes { kp in
        iv.withUnsafeBytes { ivp in
          data.withUnsafeBytes { dp in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                    kp.baseAddress, keyLen,
                    ivp.baseAddress,
                    dp.baseAddress, data.count,
                    outPtr, outCapacity, &outLen)
          }
        }
      }
    } else {
      status = key.withUnsafeBytes { kp in
        data.withUnsafeBytes { dp in
          CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                  kp.baseAddress, keyLen,
                  nil,
                  dp.baseAddress, data.count,
                  outPtr, outCapacity, &outLen)
        }
      }
    }
    guard status == kCCSuccess else { throw NSError(domain: "LX", code: -6, userInfo: [NSLocalizedDescriptionKey: "AES failed \(status)"]) }
    return Array(UnsafeBufferPointer(start: outPtr, count: Int(outLen)))
  }

  /// 原始 AES 单块加密（16 字节，ECB 无填充），作为 CFB/CTR/OFB 的块原语
  private static func aesBlockEncrypt(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
    var b = block
    if b.count < 16 { b += [UInt8](repeating: 0, count: 16 - b.count) }
    let inBytes = Array(b.prefix(16))
    var out = [UInt8](repeating: 0, count: 16)
    var outLen: size_t = 0
    key.withUnsafeBytes { kp in
      inBytes.withUnsafeBytes { dp in
        out.withUnsafeMutableBytes { op in
          _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                      CCOptions(kCCOptionECBMode), // 无 PKCS7（输入整块）
                      kp.baseAddress, key.count, nil,
                      dp.baseAddress, 16,
                      op.baseAddress, 16, &outLen)
        }
      }
    }
    return Array(out.prefix(Int(outLen)))
  }

  /// CTR 计数器大端自增（16 字节）
  private static func incrementCounter(_ c: inout [UInt8]) {
    for i in stride(from: 15, through: 0, by: -1) {
      if c[i] == 255 { c[i] = 0 }
      else { c[i] += 1; break }
    }
  }

  /// 原始 RSA（RSA_NO_PADDING）：m^e mod n，左补 0 到模长。对齐 LX 脚本沙箱 rsaEncrypt
  static func rsaEncrypt(data: [UInt8], pemKey: String) throws -> [UInt8] {
    // 解析 PKCS#1 RSAPublicKey / SubjectPublicKeyInfo（BEGIN PUBLIC KEY / RSA PUBLIC KEY）
    let base64 = pemKey
      .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
    guard let der = Data(base64Encoded: base64) else {
      throw NSError(domain: "LX", code: -7, userInfo: [NSLocalizedDescriptionKey: "RSA pem decode failed"])
    }
    guard let ints = derInts([UInt8](der)), ints.count >= 2 else {
      throw NSError(domain: "LX", code: -7, userInfo: [NSLocalizedDescriptionKey: "RSA key parse failed"])
    }
    // 模数取最大 INTEGER，指数取最小 INTEGER
    let modulus = ints.max { $0.count < $1.count } ?? ints[0]
    let exponent = ints.min { $0.count < $1.count } ?? ints[ints.count - 1]

    // 消息左补 0 到模长；超长报错
    guard data.count <= modulus.count else {
      throw NSError(domain: "LX", code: -7, userInfo: [NSLocalizedDescriptionKey: "RSA message too long"])
    }
    let msg = [UInt8](repeating: 0, count: modulus.count - data.count) + data
    let m = RsaBig.fromBE(msg)
    let n = RsaBig.fromBE(Array(modulus))
    let e = RsaBig.fromBE(Array(exponent))
    let c = RsaBig.modPow(m, e, n)
    return RsaBig.toBE(c, padTo: modulus.count)
  }

  /// 内嵌 RSA 大数（little-endian 字节数组，index 0 = 低位；除以/移位安全）
  private enum RsaBig {
    static func fromBE(_ be: [UInt8]) -> [UInt8] {
      var le = Array(be.reversed())
      trim(&le)
      return le.isEmpty ? [0] : le
    }
    static func toBE(_ le: [UInt8], padTo: Int) -> [UInt8] {
      var rev = Array(le.reversed())
      while rev.count < padTo { rev.insert(0, at: 0) }
      return Array(rev.prefix(padTo))
    }
    static func trim(_ le: inout [UInt8]) {
      while le.count > 1 && le[le.count - 1] == 0 { le.removeLast() }
    }
    static func isZero(_ le: [UInt8]) -> Bool { le.allSatisfy { $0 == 0 } }
    static func isOdd(_ le: [UInt8]) -> Bool { le[0] & 1 == 1 }

    /// 大数加（可处理进位溢出多一位）
    static func add(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
      let n = max(a.count, b.count)
      var out = [UInt8](repeating: 0, count: n + 1)
      var carry: UInt16 = 0
      for i in 0..<n {
        let av = i < a.count ? UInt16(a[i]) : 0
        let bv = i < b.count ? UInt16(b[i]) : 0
        let s = av + bv + carry
        out[i] = UInt8(s & 0xff)
        carry = s >> 8
      }
      out[n] = UInt8(carry)
      var r = out; trim(&r); return r
    }

    /// 大数减：前提 a >= b，返回 a-b
    static func sub(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
      var out = a
      var borrow: Int = 0
      for i in 0..<a.count {
        let bv = i < b.count ? Int(b[i]) : 0
        var d = Int(a[i]) - bv - borrow
        if d < 0 { d += 256; borrow = 1 } else { borrow = 0 }
        out[i] = UInt8(d)
      }
      var r = out; trim(&r); return r
    }

    /// 大数左移一位（×2）
    static func shl1(_ a: [UInt8]) -> [UInt8] {
      var out = a
      var carry: UInt8 = 0
      for i in 0..<a.count {
        let cur = a[i]
        out[i] = (cur << 1) | carry
        carry = (cur & 0x80) >> 7
      }
      if carry != 0 { out.append(carry) }
      return out
    }

    /// 大数右移一位（÷2）
    static func shr1(_ a: [UInt8]) -> [UInt8] {
      var out = a
      var carry: UInt8 = 0
      for i in stride(from: a.count - 1, through: 0, by: -1) {
        let cur = a[i]
        out[i] = (cur >> 1) | carry
        carry = (cur & 1) << 7
      }
      var r = out; trim(&r); return r
    }

    static func cmp(_ a: [UInt8], _ b: [UInt8]) -> Int {
      if a.count != b.count { return a.count < b.count ? -1 : 1 }
      for i in stride(from: a.count - 1, through: 0, by: -1) {
        if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
      }
      return 0
    }

    /// 大数乘（schoolbook，O(n²)）
    static func mul(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
      if isZero(a) || isZero(b) { return [0] }
      var out = [UInt8](repeating: 0, count: a.count + b.count)
      for i in 0..<a.count {
        var carry: UInt16 = 0
        for j in 0..<b.count {
          let cur = UInt16(out[i + j]) + UInt16(a[i]) * UInt16(b[j]) + carry
          out[i + j] = UInt8(cur & 0xff)
          carry = cur >> 8
        }
        var k = i + b.count
        while carry > 0 {
          let cur = UInt16(out[k]) + carry
          out[k] = UInt8(cur & 0xff)
          carry = cur >> 8
          k += 1
        }
      }
      var r = out; trim(&r); return r
    }

    /// 大数取模（二进制长除法：m 左移对齐 r 的最高位，从高位逐位移位减）
    static func mod(_ a: [UInt8], _ m: [UInt8]) -> [UInt8] {
      if isZero(m) { return a }
      if cmp(a, m) < 0 { return a }
      var r = a
      let rMsb = msb(r), mMsb = msb(m)
      var shifted = m
      for _ in 0..<(rMsb - mMsb) { shifted = shl1(shifted) }
      for _ in 0...(rMsb - mMsb) {
        if cmp(r, shifted) >= 0 { r = sub(r, shifted) }
        shifted = shr1(shifted)
      }
      while cmp(r, m) >= 0 { r = sub(r, m) }
      return r
    }
    private static func leadingZeroBits(_ byte: UInt8) -> Int {
      var b = byte, c = 0
      while b != 0 { b >>= 1; c += 1 }
      return 8 - c
    }
    private static func msb(_ x: [UInt8]) -> Int {
      x.count * 8 - leadingZeroBits(x[x.count - 1]) - 1
    }

    /// 模幂：base^exp mod mod（平方-乘法）
    static func modPow(_ base: [UInt8], _ exp: [UInt8], _ m: [UInt8]) -> [UInt8] {
      var result: [UInt8] = [1]
      var b = mod(base, m)
      var e = exp
      while !isZero(e) {
        if isOdd(e) { result = mod(mul(result, b), m) }
        b = mod(mul(b, b), m)
        e = shr1(e)
      }
      return result
    }
  }

  /// 解析 DER 中所有 INTEGER 的内容（大端字节）。递归进入 SEQUENCE/BIT STRING 容器，
  /// 以取出 RSA 的 modulus/exponent（SPKI 与 PKCS#1 均适用）。
  private static func derInts(_ bytes: [UInt8]) -> [[UInt8]]? {
    var ints: [[UInt8]] = []
    func walk(_ b: [UInt8]) {
      var i = 0
      while i < b.count {
        let tag = b[i]
        guard i + 1 < b.count else { break }
        var len = Int(b[i + 1])
        var header = 2
        if len & 0x80 != 0 {
          let nlen = len & 0x7f
          guard i + 2 + nlen <= b.count else { break }
          len = 0
          for j in 0..<nlen { len = len << 8 | Int(b[i + 2 + j]) }
          header = 2 + nlen
        }
        let start = i + header
        guard start + len <= b.count else { break }
        switch tag {
        case 0x02: // INTEGER
          ints.append(Array(b[start..<(start + len)]))
        case 0x30: // SEQUENCE → 递归找 INTEGER
          walk(Array(b[start..<(start + len)]))
        case 0x03: // BIT STRING → 内容首字节为 unused-bits 计数，跳过再递归
          walk(Array(b[(start + 1)..<(start + len)]))
        default:
          break
        }
        i = start + len
      }
    }
    walk(bytes)
    return ints
  }
}

// zlib helpers 直接复用 SourceScriptParser.compress/decompress（internal）

// MARK: - verifyUrl 探针
/// 对齐 shared/utils.ts:43-56：
/// - GET + `Range: bytes=0-1`，收到响应头即取消，不做完整 body 下载；
/// - 跟随重定向（自定义 delegate 需自行实现 willPerformHTTPRedirection）；
/// - 仅 2xx 视为成功，返回最终响应 URL 的绝对字符串（对应 `resp.history` 末项）。
private final class URLRangeProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?

  func finalURL(for url: URL) async throws -> String {
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "GET"
    request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    let task = session.dataTask(with: request)
    let result: String = try await withCheckedThrowingContinuation { cont in
      lock.lock()
      continuation = cont
      lock.unlock()
      task.resume()
    }
    session.finishTasksAndInvalidate()
    return result
  }

  /// 跟随重定向并保留 Range（对标 request 的默认重定向链）。
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    var redirected = request
    redirected.httpMethod = "GET"
    redirected.setValue("bytes=0-1", forHTTPHeaderField: "Range")
    completionHandler(redirected)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200..<300).contains(code) else {
      completionHandler(.cancel)
      resolve(url: nil, code: code, error: nil)
      return
    }
    // 最终响应 URL = resp.history 末项；响应头到手即取消，避免下载完整 body
    completionHandler(.cancel)
    resolve(url: response.url?.absoluteString, code: code, error: nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // 若已由 didReceive response resolve，则 continuation 已清空，此处为 no-op
    resolve(url: nil, code: nil, error: error)
  }

  private func resolve(url: String?, code: Int?, error: Error?) {
    lock.lock()
    guard let cont = continuation else { lock.unlock(); return }
    continuation = nil
    lock.unlock()
    if let error {
      cont.resume(throwing: error)
    } else if let url, let code, (200..<300).contains(code) {
      cont.resume(returning: url)
    } else {
      cont.resume(throwing: NSError(domain: "LX", code: -5,
                                    userInfo: [NSLocalizedDescriptionKey: "verifyUrl 失败（HTTP \(code ?? -1)）"]))
    }
  }
}
