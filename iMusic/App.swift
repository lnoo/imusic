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
  let library = LibraryStore.shared
  let downloads = DownloadStore.shared
  let openApi = OpenApiServer()

  init() {
    player.attach(engine: engine)
    player.searcher = search
    syncQualityMap()
    engine.loadProxy()
    engine.onUpdateAlert = { [weak self] alert in
      Task { @MainActor in self?.api.updateAlert = alert }
    }
    openApi.onCommand = { [weak self] path in
      self?.handleOpenApi(path) ?? "{\"ok\":false}"
    }
    openApi.start() // 默认启用 openAPI
    Task { await reloadSource() }
  }

  /// openApi 动作映射（播放控制子集）
  private func handleOpenApi(_ path: String) -> String {
    func songJSON(_ s: MusicInfo?) -> String {
      guard let s else { return "null" }
      let d = try? JSONSerialization.data(withJSONObject: ["name": s.name, "singer": s.singer, "source": s.source.rawValue, "songmid": s.songmid])
      return String(data: d ?? Data(), encoding: .utf8) ?? "null"
    }
    switch path {
    case "/status":
      return "{\"ok\":true,\"playing\":\(player.isPlaying),\"mode\":\"\(player.mode.rawValue)\",\"progress\":\(player.progress),\"song\":\(songJSON(player.current))}"
    case "/play": player.togglePlay(true); return "{\"ok\":true}"
    case "/pause": player.togglePlay(false); return "{\"ok\":true}"
    case "/toggle": player.toggle(); return "{\"ok\":true}"
    case "/next": player.next(); return "{\"ok\":true}"
    case "/prev": player.prev(); return "{\"ok\":true}"
    case "/lyric": return "{\"ok\":true,\"lyric\":\((player.lyric?.lyric ?? "").jsonEscaped)}"
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