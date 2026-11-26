import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 源管理页（Spotify 深色卡片式，与主界面统一）
// 导入矩阵：JS 脚本 / JSON 清单 × 在线 URL / 本地文件
// JSON 清单只提供 { id, name, url }，按条目下载 JS 后复用 UserApiStore 的原有管线。

struct SourceSettingsView: View {
  @Environment(AppState.self) private var state
  @Environment(UserApiStore.self) private var api
  @Environment(UserApiEngine.self) private var engine

  private enum ImportMode: String, CaseIterable { case js, json }
  private enum NoticeKind { case error, success }

  @State private var importMode: ImportMode = .js
  @State private var urlInput = ""
  @State private var busy = false
  @State private var busyLabel: String?
  @State private var importingEntryID: String?
  @State private var importedEntryIDs: Set<String> = []
  @State private var manifest: [ManifestSource] = []
  @State private var manifestLabel = ""
  @State private var entryFilter = ""
  @State private var error: String?
  @State private var importNote: String?
  @State private var showJSImporter = false
  @State private var showJSONImporter = false

  // GD音乐台签名服务：@State 镜像 + 写穿到 ALGdSign（UserDefaults）
  @State private var signServerUrl = ALGdSign.signServerUrl
  @State private var signKey = ALGdSign.signKey
  @State private var useOrgSource = ALGdSign.useOrgSource
  @State private var preloadQualityOnSearch = ALGdSign.preloadQualityOnSearch

  private var trimmedURL: String { urlInput.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var canSubmit: Bool {
    !busy && (trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://"))
  }

  /// 启用源排前面（保持优先级顺序），其余排在后面
  private var orderedInfos: [UserApiInfo] {
    let enabled = api.enabledSourceIds.compactMap { id in api.list.first { $0.id == id } }
    let rest = api.list.filter { !api.enabledSourceIds.contains($0.id) }
    return enabled + rest
  }

  private var capsText: String {
    engine.sources.map { kv in
      let a = kv.value.actions.map { $0.rawValue }.joined(separator: ",")
      let q = kv.value.qualitys.map { $0.rawValue }.joined(separator: ",")
      return "\(kv.key):\(a)[\(q)]"
    }.joined(separator: "  ")
  }

  private var filteredEntries: [ManifestSource] {
    let q = entryFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return manifest }
    return manifest.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
  }

  private var remainingSlots: Int { max(0, 20 - api.list.count) }

  /// 内置源能力标签（搜索/榜单/歌词/封面/播放兜底）
  static func capTicks(_ cap: SourceCapability) -> String {
    var t: [String] = []
    if cap.search != nil { t.append("搜索") }
    if cap.board != nil { t.append("榜单") }
    if cap.lyric != nil { t.append("歌词") }
    if cap.pic != nil { t.append("封面") }
    if cap.fallbackUrl != nil { t.append("播放") }
    return t.joined(separator: "·")
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.spaceMD) {
        header
        currentSourceCard
        importCard
        installedCard
        builtinCard
        gdSignCard
      }
      .padding(Theme.spaceLG)
      .spotifyScrollbar()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
    .fileImporter(isPresented: $showJSImporter, allowedContentTypes: [.javaScript, .plainText]) { result in
      handleJSFile(result)
    }
    .fileImporter(isPresented: $showJSONImporter, allowedContentTypes: [.json]) { result in
      handleManifestFile(result)
    }
  }

  // MARK: - 区块

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("音源设置")
        .font(Theme.display())
        .foregroundStyle(Theme.text)
      Text("导入 JS 脚本或 JSON 清单，支持在线地址与本地文件；最多启用 3 个源，按列表顺序决定优先级（靠前者优先）。")
        .font(Theme.bodySM())
        .foregroundStyle(Theme.text2)
    }
  }

  private var currentSourceCard: some View {
    settingsCard(title: "启用的源（最多 \(UserApiStore.maxEnabledSources) 个 · 顺序即优先级）") {
      if api.list.isEmpty {
        Text("暂未导入自定义源，当前使用内置搜索与播放。")
          .font(Theme.body())
          .foregroundStyle(Theme.text2)
      } else {
        ForEach(Array(orderedInfos.enumerated()), id: \.element.id) { _, info in
          let enabled = api.isEnabled(id: info.id)
          let rank = api.enabledSourceIds.firstIndex(of: info.id)
          HStack(spacing: 8) {
            Button { toggleEnabled(info.id) } label: {
              Image(systemName: enabled ? "checkmark.square.fill" : "square")
                .foregroundStyle(enabled ? Theme.accent : Theme.text2)
            }
            .buttonStyle(.plain)
            .help(enabled ? "停用此源" : "启用此源（最多 3 个）")

            VStack(alignment: .leading, spacing: 1) {
              Text("\(info.name) (\(info.version))")
                .font(Theme.body())
                .foregroundStyle(enabled ? Theme.text : Theme.text2)
              if let rank {
                Text("优先级 \(rank + 1)")
                  .font(Theme.monoCaption())
                  .foregroundStyle(Theme.text2)
              }
            }
            Spacer()
            if enabled {
              Button { moveEnabled(info.id, by: -1) } label: {
                Image(systemName: "chevron.up")
              }
              .buttonStyle(.plain)
              .foregroundStyle(Theme.text2)
              .disabled(rank == 0)
              .help("提高优先级")
              Button { moveEnabled(info.id, by: 1) } label: {
                Image(systemName: "chevron.down")
              }
              .buttonStyle(.plain)
              .foregroundStyle(Theme.text2)
              .disabled(rank == api.enabledSourceIds.count - 1)
              .help("降低优先级")
            }
          }
          .padding(.vertical, 2)
        }
      }

      HStack(spacing: 6) {
        Text("状态")
          .font(Theme.body())
          .foregroundStyle(Theme.text2)
        Spacer()
        if !api.enabledSourceIds.isEmpty && !engine.inited && api.statusMessage.contains("加载") {
          ProgressView().controlSize(.small)
        }
        Text(api.statusMessage)
          .font(Theme.caption())
          .foregroundStyle(Theme.text2)
          .multilineTextAlignment(.trailing)
        Button {
          Task { await state.reloadSource() }
        } label: {
          Label("重新加载", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .font(Theme.caption())
        .foregroundStyle(Theme.text2)
        .help("按当前顺序重新加载全部启用源")
      }

      if engine.inited {
        HStack(alignment: .top, spacing: 6) {
          Text("已声明能力")
            .font(Theme.body())
            .foregroundStyle(Theme.text2)
          Spacer()
          Text(capsText)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Theme.text2)
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
        }
      }

      HStack(spacing: 8) {
        Spacer()
        Button { exportSources() } label: {
          Label("导出源", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .font(Theme.caption(.semibold))
        .foregroundStyle(Theme.accent)
        .disabled(api.list.isEmpty)
        .help("把每个已导入脚本导出为 <名称>.js")
      }
    }
  }

  /// 勾选/取消勾选后立刻按新顺序重载沙箱
  private func toggleEnabled(_ id: String) {
    var ids = api.enabledSourceIds
    if let index = ids.firstIndex(of: id) {
      ids.remove(at: index)
    } else {
      guard ids.count < UserApiStore.maxEnabledSources else {
        error = "最多只能启用 \(UserApiStore.maxEnabledSources) 个源，请先停用其他源。"
        return
      }
      ids.append(id)
    }
    clearNotice()
    api.setEnabled(ids)
    Task { await state.reloadSource() }
  }

  private func moveEnabled(_ id: String, by delta: Int) {
    var ids = api.enabledSourceIds
    guard let from = ids.firstIndex(of: id) else { return }
    let to = from + delta
    guard ids.indices.contains(to) else { return }
    ids.swapAt(from, to)
    clearNotice()
    api.setEnabled(ids)
    Task { await state.reloadSource() }
  }

  /// 对标 command.ts exportSources：选择目录，按 <name>.js 写出全部已导入脚本
  private func exportSources() {
    let sources = api.exportSources()
    guard !sources.isEmpty else {
      error = "没有可导出的源。"
      return
    }
    let panel = NSOpenPanel()
    panel.title = "导出自定义源"
    panel.message = "选择保存目录，每个源会写成 <名称>.js"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let dir = panel.url else { return }

    let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
    var failed: [String] = []
    for item in sources {
      let base = item.name.components(separatedBy: invalid).joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let fileName = (base.isEmpty ? "source" : base) + ".js"
      do {
        try item.script.write(to: dir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
      } catch {
        failed.append(item.name)
      }
    }
    clearNotice()
    if failed.isEmpty {
      importNote = "已导出 \(sources.count) 个源到「\(dir.lastPathComponent)」。"
    } else {
      error = "导出失败：\(failed.prefix(2).joined(separator: "、"))"
    }
  }

  private var importCard: some View {
    settingsCard(title: "导入音源") {
      Picker("源格式", selection: $importMode) {
        Text("JS 脚本").tag(ImportMode.js)
        Text("JSON 清单").tag(ImportMode.json)
      }
      .pickerStyle(.segmented)
      .tint(Theme.accent)
      .onChange(of: importMode) { _, _ in clearNotice() }

      Text(importMode == .js
           ? "导入单个 LX 自定义源脚本（.js），有空位时自动启用（最多 3 个）。"
           : "读取音源清单（sources.json），预览后再按需下载其中的 JS 脚本。")
        .font(Theme.caption())
        .foregroundStyle(Theme.text2)

      // 在线
      VStack(alignment: .leading, spacing: Theme.spaceXS) {
        Text("在线地址")
          .font(Theme.caption(.semibold))
          .foregroundStyle(Theme.text2)
        HStack(spacing: 8) {
          TextField(importMode == .js ? "https://…/source.js" : "https://…/sources.json", text: $urlInput)
            .textFieldStyle(.plain)
            .font(Theme.body())
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
              RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .fill(Theme.field)
            )
            .onSubmit { Task { await submitOnline() } }

          Button {
            Task { await submitOnline() }
          } label: {
            HStack(spacing: 4) {
              if busy { ProgressView().controlSize(.small) }
              Text(buttonTitle)
                .font(Theme.body(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.black)
          .background(Capsule().fill(canSubmit ? Theme.accent : Theme.cardHover))
          .disabled(!canSubmit)
        }
      }

      // 本地
      HStack {
        Text("本地文件")
          .font(Theme.caption(.semibold))
          .foregroundStyle(Theme.text2)
        Spacer()
        Button {
          if importMode == .js { showJSImporter = true } else { showJSONImporter = true }
        } label: {
          Label(importMode == .js ? "选择 .js 文件" : "选择 .json 清单",
                systemImage: "folder")
        }
        .buttonStyle(.plain)
        .font(Theme.caption(.semibold))
        .foregroundStyle(Theme.accent)
        .disabled(busy)
      }
      .padding(.top, 2)

      if importMode == .json && !manifest.isEmpty {
        manifestList
      }

      if let e = error { notice(e, kind: .error) }
      if let n = importNote { notice(n, kind: .success) }
    }
  }

  private var manifestList: some View {
    VStack(alignment: .leading, spacing: Theme.spaceXS) {
      HStack(spacing: 6) {
        Text("清单内容 · \(manifest.count) 个音源")
          .font(Theme.body(.semibold))
          .foregroundStyle(Theme.text)
        Spacer()
        if !manifestLabel.isEmpty {
          Text(manifestLabel)
            .font(Theme.monoCaption())
            .foregroundStyle(Theme.text2)
            .lineLimit(1)
            .help(manifestLabel)
        }
      }

      TextField("筛选名称或 id", text: $entryFilter)
        .textFieldStyle(.plain)
        .font(Theme.bodySM())
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.card))

      if filteredEntries.isEmpty {
        Text("没有匹配的音源")
          .font(Theme.caption())
          .foregroundStyle(Theme.text2)
      } else {
        LazyVStack(spacing: 2) {
          ForEach(filteredEntries) { entry in
            manifestEntryRow(entry)
          }
        }
        .frame(maxHeight: 240)
      }

      HStack(spacing: 8) {
        Button {
          Task { await importAllEntries() }
        } label: {
          Text("导入全部可用 (\(max(0, manifest.count - importedEntryIDs.count)))")
            .font(Theme.caption(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .disabled(busy || importedEntryIDs.count >= manifest.count || remainingSlots == 0)

        Spacer()

        Button("清空清单") {
          manifest = []; manifestLabel = ""; importedEntryIDs = []; entryFilter = ""
        }
        .buttonStyle(.plain)
        .font(Theme.caption())
        .foregroundStyle(Theme.text2)
      }

      if manifest.count > remainingSlots {
        Text("当前最多可再导入 \(remainingSlots) 个源（上限 20），超出部分会被拒绝。")
          .font(Theme.caption())
          .foregroundStyle(Theme.warning)
      }
    }
    .padding(Theme.spaceSM)
    .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.field))
  }

  private func manifestEntryRow(_ entry: ManifestSource) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(entry.name)
            .font(Theme.body())
            .foregroundStyle(Theme.text)
          Text(entry.id)
            .font(Theme.monoCaption())
            .foregroundStyle(Theme.text2)
        }
        Text(entry.url)
          .font(Theme.monoCaption())
          .foregroundStyle(Theme.text2)
          .lineLimit(1)
          .help(entry.url)
      }
      Spacer()
      if importingEntryID == entry.id {
        ProgressView().controlSize(.small)
      } else if importedEntryIDs.contains(entry.id) {
        Label("已导入", systemImage: "checkmark.circle.fill")
          .font(Theme.caption())
          .foregroundStyle(Theme.accent)
      } else {
        Button("导入") {
          Task { await importEntry(entry) }
        }
        .buttonStyle(.plain)
        .font(Theme.caption(.semibold))
        .foregroundStyle(Theme.accent)
        .disabled(busy)
      }
    }
    .padding(.vertical, 4)
  }

  private var installedCard: some View {
    settingsCard(title: "已导入的源 \(api.list.count)/20") {
      if api.list.isEmpty {
        Text("暂未导入任何自定义源，当前使用内置搜索与播放。")
          .font(Theme.body())
          .foregroundStyle(Theme.text2)
      } else {
        ForEach(api.list) { info in
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(info.name)
                  .font(Theme.body(.semibold))
                  .foregroundStyle(Theme.text)
                Text("v\(info.version)")
                  .font(Theme.caption())
                  .foregroundStyle(Theme.text2)
                sourceBadge(info)
              }
              if !info.description.isEmpty {
                Text(info.description)
                  .font(Theme.caption())
                  .foregroundStyle(Theme.text2)
                  .lineLimit(1)
              }
            }
            Spacer()
            HStack(spacing: 8) {
              Button(api.isEnabled(id: info.id) ? "停用" : "启用") { toggleEnabled(info.id) }
                .buttonStyle(.plain)
                .font(Theme.caption(.semibold))
                .foregroundStyle(api.isEnabled(id: info.id) ? Theme.accent : Theme.text)
              Button("删除") { api.remove(ids: [info.id]); Task { await state.reloadSource() } }
                .buttonStyle(.plain)
                .font(Theme.caption(.semibold))
                .foregroundStyle(Theme.danger)
            }
          }
          .padding(.vertical, 4)
        }
      }
      Text("自定义源生效时，播放/歌词/封面走脚本声明的能力；内置源仅承担搜索与榜单。")
        .font(Theme.caption())
        .foregroundStyle(Theme.text2)
    }
  }

  private func sourceBadge(_ info: UserApiInfo) -> some View {
    let text = info.manifestURL == nil ? "JS" : "清单 · \(info.sourceId ?? "")"
    return Text(text)
      .font(Theme.monoCaption())
      .foregroundStyle(Theme.text2)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(RoundedRectangle(cornerRadius: 4).fill(Theme.cardHover))
  }

  private var builtinCard: some View {
    settingsCard(title: "内置源能力") {
      ForEach(SourceRegistry.all.filter { $0.id != "local" }, id: \.id) { cap in
        HStack {
          Text(cap.displayName)
            .font(Theme.body())
            .foregroundStyle(Theme.text)
          Spacer()
          Text(SourceSettingsView.capTicks(cap))
            .font(Theme.caption())
            .foregroundStyle(Theme.text2)
        }
      }
    }
  }

  /// GD音乐台签名服务：org 音源（tencent/tidal/qobuz/apple/ytmusic/spotify）
  /// 以及开启 useOrgSource 后的主 API 音源，请求需由签名服务器组装后原样直发。
  private var gdSignCard: some View {
    settingsCard(title: "GD音乐台签名服务") {
      VStack(alignment: .leading, spacing: Theme.spaceXS) {
        Text("org 音源（QQ音乐/TIDAL/QOBUZ/Apple Music/YouTube Music/Spotify）经签名服务器直连；签名仅 5~15 秒有效，每次请求实时获取。")
          .font(Theme.caption())
          .foregroundStyle(Theme.text2)

        fieldLabel("服务地址")
        TextField("https://sign.example.com", text: $signServerUrl)
          .textFieldStyle(.plain)
          .font(Theme.body())
          .foregroundStyle(Theme.text)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.field))
          .onChange(of: signServerUrl) { _, new in ALGdSign.signServerUrl = new }

        fieldLabel("签名密钥")
        SecureField("Bearer Token", text: $signKey)
          .textFieldStyle(.plain)
          .font(Theme.body())
          .foregroundStyle(Theme.text)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.field))
          .onChange(of: signKey) { _, new in ALGdSign.signKey = new }

        HStack {
          Text("所有音源都走签名服务器")
            .font(Theme.body())
            .foregroundStyle(Theme.text)
          Spacer()
          Toggle("", isOn: $useOrgSource)
            .labelsHidden()
            .tint(Theme.accent)
            .onChange(of: useOrgSource) { _, new in ALGdSign.useOrgSource = new }
        }

        HStack {
          Text("搜索时预加载音质")
            .font(Theme.body())
            .foregroundStyle(Theme.text)
          Spacer()
          Toggle("", isOn: $preloadQualityOnSearch)
            .labelsHidden()
            .tint(Theme.accent)
            .onChange(of: preloadQualityOnSearch) { _, new in ALGdSign.preloadQualityOnSearch = new }
        }

        Label(ALGdSign.hasConfig ? "签名服务已配置" : "尚未配置签名服务，org 音源将不可用",
              systemImage: ALGdSign.hasConfig ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(Theme.caption())
          .foregroundStyle(ALGdSign.hasConfig ? Theme.accent : Theme.warning)
      }
    }
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text)
      .font(Theme.caption(.semibold))
      .foregroundStyle(Theme.text2)
  }

  // MARK: - 操作

  private var buttonTitle: String {
    guard !busy else { return busyLabel ?? "处理中…" }
    return importMode == .js ? "立即导入" : "读取清单"
  }

  private func clearNotice() {
    error = nil
    importNote = nil
  }

  /// 清单载入后回填已导入状态，避免重复导入同一清单条目
  private func syncImportedEntryIDs() {
    importedEntryIDs = Set(api.list.compactMap { info in
      guard info.manifestURL == manifestLabel, let sid = info.sourceId else { return nil }
      return sid
    })
  }

  private func submitOnline() async {
    clearNotice()
    guard canSubmit else {
      error = SourceImportError.invalidURL.localizedDescription
      return
    }
    busy = true
    busyLabel = importMode == .js ? "导入中…" : "读取中…"
    defer { busy = false; busyLabel = nil }
    do {
      if importMode == .js {
        let info = try await api.importFromURL(trimmedURL)
        let enabled = autoEnableAfterImport(info.id)
        if enabled { await state.reloadSource() }
        importNote = enabled
          ? "已导入并启用「\(info.name)」。"
          : "已导入「\(info.name)」（启用数已达上限，请在上方手动勾选）。"
      } else {
        let entries = try await api.fetchManifest(from: trimmedURL)
        manifest = entries
        manifestLabel = trimmedURL
        syncImportedEntryIDs()
        entryFilter = ""
        importNote = "已读取清单，共 \(entries.count) 个音源，选择后导入。"
      }
    } catch let e {
      error = e.localizedDescription
    }
  }

  private func importEntry(_ entry: ManifestSource) async {
    clearNotice()
    importingEntryID = entry.id
    defer { importingEntryID = nil }
    do {
      let info = try await api.importFromManifest(entry, manifestURL: manifestLabel)
      importedEntryIDs.insert(entry.id)
      importNote = "已导入「\(info.name)」（清单 id：\(entry.id)）。"
    } catch let e {
      error = e.localizedDescription
    }
  }

  private func importAllEntries() async {
    clearNotice()
    let capacity = remainingSlots
    guard !manifest.isEmpty, capacity > 0 else { return }
    busy = true
    busyLabel = "导入中…"
    defer { busy = false; busyLabel = nil; importingEntryID = nil }
    var ok = 0
    var failed: [String] = []
    for entry in manifest where !importedEntryIDs.contains(entry.id) {
      if ok >= capacity { break }
      importingEntryID = entry.id
      do {
        _ = try await api.importFromManifest(entry, manifestURL: manifestLabel)
        importedEntryIDs.insert(entry.id)
        ok += 1
      } catch let e {
        failed.append("\(entry.name)：\(e.localizedDescription)")
      }
    }
    if failed.isEmpty {
      importNote = "已导入 \(ok) 个音源。"
    } else {
      error = "成功 \(ok) 个，失败 \(failed.count) 个：\(failed.prefix(2).joined(separator: "；"))"
    }
  }

  private func handleJSFile(_ result: Result<URL, Error>) {
    clearNotice()
    do {
      let url = try result.get()
      let info = try api.importFromFile(url)
      let enabled = autoEnableAfterImport(info.id)
      if enabled { Task { await state.reloadSource() } }
      importNote = enabled
        ? "已从本地导入并启用「\(info.name)」。"
        : "已从本地导入「\(info.name)」（启用数已达上限，请手动勾选）。"
    } catch let e {
      error = e.localizedDescription
    }
  }

  /// 导入后自动启用（仍有空位时），返回是否发生了启用变化
  private func autoEnableAfterImport(_ id: String) -> Bool {
    guard !api.isEnabled(id: id), api.enabledSourceIds.count < UserApiStore.maxEnabledSources else { return false }
    api.setEnabled(api.enabledSourceIds + [id])
    return true
  }

  private func handleManifestFile(_ result: Result<URL, Error>) {
    clearNotice()
    do {
      let url = try result.get()
      let entries = try api.loadManifest(from: url)
      manifest = entries
      manifestLabel = "local://\(url.lastPathComponent)"
      syncImportedEntryIDs()
      entryFilter = ""
      importNote = "已读取本地清单，共 \(entries.count) 个音源，选择后导入。"
    } catch let e {
      error = e.localizedDescription
    }
  }

  // MARK: - 通用组件

  private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Theme.spaceSM) {
      Text(title)
        .font(Theme.title())
        .foregroundStyle(Theme.text)
      content()
    }
    .padding(Theme.spaceMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
        .fill(Theme.card)
    )
  }

  private func notice(_ text: String, kind: NoticeKind) -> some View {
    Label(text, systemImage: kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
      .font(Theme.caption())
      .foregroundStyle(kind == .error ? Theme.danger : Theme.accent)
      .padding(Theme.spaceSM)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
          .fill(Theme.card)
      )
  }
}
