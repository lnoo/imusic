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
  var inited = false
  var message = "未加载"
  var sources: [String: UserApiSourceInfo] = [:]
  var qualitys: [String: [MusicQuality]] = [:]

  private var ctx: JSContext?
  private var requestHandler: JSValue?
  private var pending: [String: CheckedContinuation<JSValue, Error>] = [:]
  private var tasks: [String: URLSessionDataTask] = [:]
  private var meta: SourceScriptMeta = SourceScriptMeta(name: "", description: "", author: "", homepage: "", version: "")
  private var rawScript = ""
  /// 代理（对标 setting network.proxy + preload getRequestAgent；host 为空即直连）
  private var netSession: URLSession = .shared

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

  // 与 preload.js 完全一致的过滤表
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
    "kw": ["musicUrl"], "kg": ["musicUrl"], "tx": ["musicUrl"],
    "wy": ["musicUrl"], "mg": ["musicUrl"], "xm": ["musicUrl"],
    "local": ["musicUrl", "lyric", "pic"],
  ]

  var onUpdateAlert: ((UpdateAlert) -> Void)?

  // MARK: load
  /// 每次 load/unload 递增；旧 JSContext 的回调用它自检，避免打进来
  private var generation = 0

  private func lxError(_ code: Int, _ msg: String) -> NSError {
    NSError(domain: "LX", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
  }

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
  func load(scriptRaw: String, meta: SourceScriptMeta) async throws {
    unload()
    let gen = generation
    self.meta = meta
    self.rawScript = scriptRaw
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
      ctx.evaluateScript(wrapped(scriptRaw))
    }
  }

  private var initedContinuation: CheckedContinuation<Void, Error>?

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
      let task = self.netSession.dataTask(with: req) { data, resp, err in
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
        self.onUpdateAlert?(alert)
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

    // rsaEncrypt：原项目 RSA_NO_PADDING（左补0到128字节）。MVP用 Security 实现 raw RSA。
    let rsa: @convention(block) (JSValue, String) -> JSValue = { buf, pemKey in
      let c = JSContext.current()!
      c.exception = JSValue(newErrorFromMessage: "rsaEncrypt unsupported in MVP (need SecKey raw RSA)", in: c)
      return JSValue(undefinedIn: c)
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

  // MARK: - 宿主 -> 脚本 request（复刻 handleRequest + 20s超时 + 响应校验）
  /// - returns: musicUrl->URL字符串；pic->URL字符串；lyric->LyricInfo
  func callScript(source: String, action: UserApiAction, quality: MusicQuality, music: MusicInfo) async throws -> Any {
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
        Task { @MainActor in
          if let c = self.pending.removeValue(forKey: id) {
            c.resume(throwing: self.lxError(-3, e.toString() ?? "script error"))
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
    var options: CCOptions = 0
    if m.contains("ecb") { options = CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode) }
    else { options = CCOptions(kCCOptionPKCS7Padding) } // CBC
    let keyLen = (m.contains("256") || key.count > 16) ? kCCKeySizeAES256 : kCCKeySizeAES128
    var keyPadded = key
    if keyPadded.count < keyLen { keyPadded += [UInt8](repeating: 0, count: keyLen - keyPadded.count) }
    else { keyPadded = Array(keyPadded.prefix(keyLen)) }
    var ivPadded = iv
    if ivPadded.count < kCCBlockSizeAES128 { ivPadded += [UInt8](repeating: 0, count: kCCBlockSizeAES128 - ivPadded.count) }
    let outCapacity = data.count + kCCBlockSizeAES128
    let outPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: outCapacity)
    defer { outPtr.deallocate() }
    var outLen: size_t = 0
    let status = keyPadded.withUnsafeBytes { kp in
      ivPadded.withUnsafeBytes { ivp in
        data.withUnsafeBytes { dp in
          CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                  kp.baseAddress, keyLen,
                  m.contains("ecb") ? nil : ivp.baseAddress,
                  dp.baseAddress, data.count,
                  outPtr, outCapacity, &outLen)
        }
      }
    }
    guard status == kCCSuccess else { throw NSError(domain: "LX", code: -6, userInfo: [NSLocalizedDescriptionKey: "AES failed \(status)"]) }
    return Array(UnsafeBufferPointer(start: outPtr, count: Int(outLen)))
  }
}

// zlib helpers 直接复用 SourceScriptParser.compress/decompress（internal）
