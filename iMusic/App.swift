import SwiftUI
import Observation
// Xcode 27 构建期会跑 AppIntentsMetadataExtractor；显式链接 AppIntents 可避免
// “Metadata extraction skipped, no AppIntents.framework dependency found” 警告。
import AppIntents

// MARK: - AppState：胶水层，对标 src/renderer/core/apiSource.ts#setUserApi
// + useInitUserApi.ts（status->构建apis/qualityList/apiInitPromise）
// + useSettingSync.ts（watch apiSource 切换即重载）
// 100% 现代 Observation 框架：细粒度精准追踪，零冗余重绘

@Observable @MainActor
final class AppState {
  let api = UserApiStore.shared
  let engine = UserApiEngine()
  let player = PlayerStore()
  let search = SearchService()
  let songlists = SonglistStore()
  let library = LibraryStore.shared
  let downloads = DownloadStore.shared
  let openApi = OpenApiServer()

  init() {
    player.attach(engine: engine)
    player.searcher = search
    // 耳机手势/媒体键/控制中心 → MPRemoteCommand → PlayerStore
    MediaRemoteController.shared.attach(to: player)
    syncQualityMap()
    engine.loadProxy()
    engine.onUpdateAlert = { [weak self] alert in
      Task { @MainActor in self?.api.updateAlert = alert }
    }
    openApi.onCommand = { [weak self] path, params in
      await self?.handleOpenApi(path, params: params) ?? "{\"ok\":false}"
    }
    openApi.start() // 默认启用 openAPI
    Task { await reloadSource() }
  }

  /// openApi 动作映射：播放控制子集 + any-listen 解析层查询路由
  private func handleOpenApi(_ path: String, params: [String: String]) async -> String {
    func songDict(_ s: MusicInfo) -> [String: Any] {
      var d: [String: Any] = ["name": s.name, "singer": s.singer, "source": s.source.rawValue,
                              "songmid": s.songmid, "albumName": s.albumName]
      if let i = s.interval { d["interval"] = i }
      if let p = s.picUrl { d["picUrl"] = p }
      d["qualitys"] = s.qualitys.map { $0.type.rawValue }
      return d
    }
    func songsJSON(_ list: [MusicInfo]) -> String {
      (list.map(songDict) as [Any]).jsonEncoded
    }
    func fail(_ msg: String) -> String {
      ["ok": false, "error": msg].jsonEncoded
    }
    func intParam(_ key: String, _ fallback: Int) -> Int {
      params[key].flatMap(Int.init) ?? fallback
    }

    switch path {
    case "/status":
      let songPart = player.current.map { songDict($0).jsonEncoded } ?? "null"
      return "{\"ok\":true,\"playing\":\(player.isPlaying),\"mode\":\"\(player.mode.rawValue)\",\"progress\":\(player.progress),\"song\":\(songPart)}"
    case "/play": player.togglePlay(true); return "{\"ok\":true}"
    case "/pause": player.togglePlay(false); return "{\"ok\":true}"
    case "/toggle": player.toggle(); return "{\"ok\":true}"
    case "/next": player.next(); return "{\"ok\":true}"
    case "/prev": player.prev(); return "{\"ok\":true}"
    case "/lyric":
      // 无 source 参数：返回当前播放歌词（历史行为）
      guard let srcRaw = params["source"], let source = MusicSource(rawValue: srcRaw), source != .local else {
        return "{\"ok\":true,\"lyric\":\((player.lyric?.lyric ?? "").jsonEscaped)}"
      }
      // 按曲取词：kg 需 hash+secs（可缺省走名称兜底）
      let song = MusicInfo(
        name: params["name"] ?? "", singer: params["singer"] ?? "",
        source: source, songmid: params["songmid"] ?? "",
        albumName: params["album"] ?? "", interval: nil, qualitys: [],
        picUrl: nil,
        extra: ["hash": params["hash"] ?? "", "intervalSecs": params["secs"] ?? "",
                "lrcUrl": params["lrcUrl"] ?? ""])
      do {
        let info = try await AnyListenResource.musicLyric(source: source, music: song)
        return ["ok": true, "lyric": info.lyric, "tlyric": info.tlyric ?? "",
                "rlyric": info.rlyric ?? "", "lxlyric": info.lxlyric ?? "",
                "awlyric": info.awlyric ?? ""].jsonEncoded
      } catch {
        return fail(error.localizedDescription)
      }
    case "/search":
      guard let srcRaw = params["source"], let source = MusicSource(rawValue: srcRaw), source != .local,
            let keyword = params["keyword"], !keyword.isEmpty else {
        return fail("需要 source 与 keyword 参数")
      }
      do {
        let r = try await AnyListenResource.musicSearch(source: source, name: keyword,
          page: intParam("page", 1), limit: min(intParam("limit", 20), 50))
        return ["ok": true, "source": srcRaw, "total": r.total, "page": r.page, "limit": r.limit,
                "list": r.list.map(songDict)].jsonEncoded
      } catch {
        return fail(error.localizedDescription)
      }
    case "/songlist/search":
      guard let srcRaw = params["source"], let source = MusicSource(rawValue: srcRaw), source != .local,
            let keyword = params["keyword"], !keyword.isEmpty else {
        return fail("需要 source 与 keyword 参数")
      }
      do {
        let r = try await AnyListenResource.songlistSearch(source: source, keyword: keyword,
          page: intParam("page", 1), limit: min(intParam("limit", 20), 50))
        return ["ok": true, "source": srcRaw, "total": r.total, "page": r.page, "limit": r.limit,
                "list": r.list.map { s -> [String: Any] in
                  var d: [String: Any] = ["id": s.id, "name": s.name]
                  if let v = s.playCount { d["playCount"] = v }
                  if let v = s.author { d["author"] = v }
                  if let v = s.img { d["img"] = v }
                  if let v = s.total { d["total"] = v }
                  return d
                }].jsonEncoded
      } catch {
        return fail(error.localizedDescription)
      }
    case "/songlist/detail":
      guard let srcRaw = params["source"], let source = MusicSource(rawValue: srcRaw), source != .local,
            let id = params["id"], !id.isEmpty else {
        return fail("需要 source 与 id 参数")
      }
      do {
        let r = try await AnyListenResource.songlistDetail(source: source, id: id,
          page: intParam("page", 1), limit: min(intParam("limit", 30), 100))
        var infoDict: [String: Any] = ["name": r.info.name]
        if let v = r.info.img { infoDict["img"] = v }
        if let v = r.info.desc { infoDict["desc"] = v }
        if let v = r.info.author { infoDict["author"] = v }
        if let v = r.info.playCount { infoDict["playCount"] = v }
        return ["ok": true, "source": srcRaw, "id": id, "total": r.total,
                "info": infoDict, "list": r.list.map(songDict)].jsonEncoded
      } catch {
        return fail(error.localizedDescription)
      }
    case "/board":
      guard let srcRaw = params["source"], let source = MusicSource(rawValue: srcRaw), source != .local else {
        return fail("需要 source 参数")
      }
      let boards = await AnyListenResource.topSongs(source: source)
      return ["ok": true, "source": srcRaw,
              "list": boards.map { ["id": $0.id, "name": $0.name, "pic": $0.pic ?? ""] }].jsonEncoded
    case "/board/detail":
      guard let srcRaw = params["source"], let source = MusicSource(rawValue: srcRaw), source != .local,
            let id = params["id"], !id.isEmpty else {
        return fail("需要 source 与 id 参数")
      }
      do {
        let r = try await AnyListenResource.topSongsDetail(source: source, id: id,
          page: intParam("page", 1), limit: min(intParam("limit", 50), 100))
        return ["ok": true, "source": srcRaw, "id": id, "total": r.total,
                "info": ["name": r.info.name, "pic": r.info.pic ?? "",
                         "desc": r.info.desc ?? "", "date": r.info.date ?? ""],
                "list": r.list.map(songDict)].jsonEncoded
      } catch {
        return fail(error.localizedDescription)
      }
    default: return "{\"ok\":false,\"error\":\"unknown path\"}"
    }
  }

  /// 同步音质表（对标 setUserApi 的 qualityList 刷新）：
  /// 自定义源生效时用脚本声明的 engine.qualitys，否则用注册表内置表
  func syncQualityMap() {
    player.qualityMap = engine.inited ? engine.qualitys : SourceRegistry.builtinQualityMap
  }

  /// 切换/重载自定义源（对标 lx-api-source-loader src/main/index.ts:9-81）
  /// 按 api.enabledSourceIds 顺序加载全部启用脚本；reloadSeq 保证并发时只认最后一次。
  private var reloadSeq = 0

  func reloadSource() async {
    reloadSeq += 1
    let seq = reloadSeq
    let ids = api.enabledSourceIds.filter { $0.hasPrefix("user_api_") }
    guard !ids.isEmpty else {
      engine.unload()
      guard seq == reloadSeq else { return }
      api.statusMessage = "当前为内置模式（无启用自定义源，仅搜索+兜底试听）"
      syncQualityMap()
      return
    }

    var specs: [UserApiEngine.ScriptSpec] = []
    var failedNames: [String] = []
    for id in ids {
      do {
        let raw = try api.rawScript(id: id)
        specs.append(UserApiEngine.ScriptSpec(id: id, scriptRaw: raw, meta: try SourceScriptParser.parseMeta(raw)))
      } catch {
        failedNames.append(error.localizedDescription)
      }
      guard seq == reloadSeq else { return }
    }

    if specs.isEmpty {
      engine.unload()
      guard seq == reloadSeq else { return }
      api.statusMessage = "源加载失败：\(failedNames.prefix(2).joined(separator: "；"))"
      syncQualityMap()
      return
    }

    api.statusMessage = "正在加载 \(specs.count) 个源…"
    await engine.loadAll(specs)
    guard seq == reloadSeq else { return }
    for spec in specs {
      api.updateInitedSources(id: spec.id, sources: engine.sources(forScript: spec.id))
    }
    api.statusMessage = engine.message
    syncQualityMap()
  }
}

@main
struct iMusicApp: App {
  @State private var state: AppState

  init() {
    _state = State(wrappedValue: AppState())
  }

  var body: some Scene {
    Window("iMusic", id: "main") {
      ContentView()
        .environment(state)
        .environment(state.api)
        .environment(state.engine)
        .environment(state.player)
        .environment(state.search)
        .environment(state.songlists)
        .environment(state.library)
        .environment(state.downloads)
        .frame(minWidth: 980, minHeight: 640)
        .focusEffectDisabled()
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: false))

    // 顶部菜单栏：暂停/上一首/下一首
    MenuBarExtra {
      MenuBarView()
        .environment(state.player)
        .focusEffectDisabled()
    } label: {
      MenuBarLabel()
        .environment(state.player)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SourceSettingsView()
        .environment(state)
        .environment(state.api)
        .environment(state.engine)
        .focusEffectDisabled()
    }
  }
}