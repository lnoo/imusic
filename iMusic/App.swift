import SwiftUI
import Observation

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
                "rlyric": info.rlyric ?? "", "lxlyric": info.lxlyric ?? ""].jsonEncoded
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

  /// 切换/重载自定义源（复刻 setUserApi：user_api_* 走沙箱，其余走内置）
  /// reloadSeq：并发 reload 时只让最后一次写状态，避免旧任务覆盖新结果
  private var reloadSeq = 0

  func reloadSource() async {
    reloadSeq += 1
    let seq = reloadSeq
    let id = api.activeSourceId
    if id.hasPrefix("user_api_") {
      do {
        let raw = try api.rawScript(id: id)
        let meta = try SourceScriptParser.parseMeta(raw)
        guard seq == reloadSeq else { return }
        api.statusMessage = "正在加载源「\(meta.name)」…"
        try await engine.load(scriptRaw: raw, meta: meta)
        guard seq == reloadSeq else { return }
        api.updateInitedSources(id: id, sources: engine.sources)
        api.statusMessage = engine.message
        syncQualityMap()
      } catch {
        guard seq == reloadSeq else { return }
        api.statusMessage = "源加载失败：\(error.localizedDescription)"
      }
    } else {
      engine.unload()
      guard seq == reloadSeq else { return }
      api.statusMessage = "当前为内置模式（无自定义源，仅搜索+兜底试听）"
      syncQualityMap()
    }
  }
}

@main
struct iMusicApp: App {
  @State private var state: AppState

  init() {
    // 必须在 AppState（及各 Store 单例）首次触盘前执行：老名字残留数据一次性搬家
    DataMigration.run()
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