import SwiftUI
import UniformTypeIdentifiers

// MARK: - 源管理页（Spotify 深色卡片式，与主界面统一）

struct SourceSettingsView: View {
  @Environment(AppState.self) private var state
  @Environment(UserApiStore.self) private var api
  @Environment(UserApiEngine.self) private var engine

  @State private var urlInput = "https://ghproxy.net/raw.githubusercontent.com/pdone/lx-music-source/main/lx/latest.js"
  @State private var importing = false
  @State private var error: String?
  @State private var showImporter = false
  @State private var importNote: String?

  private var activeBinding: Binding<String> {
    Binding(get: { api.activeSourceId }, set: { api.setActive($0) })
  }

  private var capsText: String {
    engine.sources.map { kv in
      let a = kv.value.actions.map { $0.rawValue }.joined(separator: ",")
      let q = kv.value.qualitys.map { $0.rawValue }.joined(separator: ",")
      return "\(kv.key):\(a)[\(q)]"
    }.joined(separator: "  ")
  }

  private var canImport: Bool {
    !importing && (urlInput.hasPrefix("http://") || urlInput.hasPrefix("https://"))
  }

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
        Text("音源设置")
          .font(Theme.display())
          .foregroundStyle(Theme.text)

        // 1. 当前生效源
        settingsCard(title: "当前生效源") {
          Picker("生效源", selection: activeBinding) {
            Text("内置模式 temp（仅搜索+兜底）").tag("temp")
            ForEach(api.list) { info in
              Text("\(info.name) (\(info.version))").tag(info.id)
            }
          }
          .tint(Theme.accent)

          HStack(spacing: 6) {
            Text("状态")
              .font(Theme.body())
              .foregroundStyle(Theme.text2)
            Spacer()
            if api.activeSourceId.hasPrefix("user_api_") && !engine.inited && api.statusMessage.contains("加载") {
              ProgressView().controlSize(.small)
            }
            Text(api.statusMessage)
              .font(Theme.caption())
              .foregroundStyle(Theme.text2)
              .multilineTextAlignment(.trailing)
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
        }

        // 2. 内置源能力一览
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
          Text("自定义源生效时，播放/歌词/封面走脚本声明的能力；上表仅为内置搜索与榜单能力。")
            .font(Theme.caption())
            .foregroundStyle(Theme.text2)
        }

        // 3. 在线导入
        settingsCard(title: "在线导入自定义源") {
          HStack {
            TextField("https://…/xxx.js", text: $urlInput)
              .textFieldStyle(.plain)
              .font(Theme.body())
              .foregroundStyle(Theme.text)
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                  .fill(Theme.field)
              )

            Button {
              Task {
                importing = true
                error = nil
                importNote = nil
                do {
                  let info = try await api.importFromURL(urlInput)
                  importNote = "已导入「\(info.name)」，生效源已自动切换并初始化。"
                  api.setActive(info.id)
                } catch let e {
                  error = e.localizedDescription
                }
                importing = false
              }
            } label: {
              HStack(spacing: 4) {
                if importing { ProgressView().controlSize(.small) }
                Text(importing ? "导入中…" : "立即导入")
                  .font(Theme.body(.semibold))
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .background(Capsule().fill(canImport ? Theme.accent : Theme.cardHover))
            .disabled(!canImport)
          }

          Text("已预填合集地址（ghproxy 加速）。导入后若提示初始化超时，请检查脚本是否符合 LX 规范。")
            .font(Theme.caption())
            .foregroundStyle(Theme.text2)

          if let n = importNote {
            Text(n)
              .font(Theme.caption(.semibold))
              .foregroundStyle(Theme.accent)
          }
        }

        // 4. 已安装源列表
        settingsCard(title: "已导入的源 \(api.list.count)/20") {
          if api.list.isEmpty {
            Text("暂未导入任何自定义源，当前使用内置搜索与播放。")
              .font(Theme.body())
              .foregroundStyle(Theme.text2)
          } else {
            ForEach(api.list) { info in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 6) {
                    Text(info.name)
                      .font(Theme.body(.semibold))
                      .foregroundStyle(Theme.text)
                    Text("v\(info.version)")
                      .font(Theme.caption())
                      .foregroundStyle(Theme.text2)
                  }
                  if !info.description.isEmpty {
                    Text(info.description)
                      .font(Theme.caption())
                      .foregroundStyle(Theme.text2)
                      .lineLimit(1)
                  }
                }
                Spacer()
                if api.activeSourceId == info.id {
                  Text("当前使用")
                    .font(Theme.caption(.semibold))
                    .foregroundStyle(Theme.accent)
                } else {
                  HStack(spacing: 8) {
                    Button("使用") { api.setActive(info.id) }
                      .buttonStyle(.plain)
                      .font(Theme.caption(.semibold))
                      .foregroundStyle(Theme.text)
                    Button("删除") { api.remove(ids: [info.id]) }
                      .buttonStyle(.plain)
                      .font(Theme.caption(.semibold))
                      .foregroundStyle(Theme.danger)
                  }
                }
              }
              .padding(.vertical, 4)
            }
          }

          Button("从本地 .js 导入") { showImporter = true }
            .buttonStyle(.plain)
            .font(Theme.body())
            .foregroundStyle(Theme.text2)
        }

        if let e = error {
          Label(e, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.danger)
            .font(Theme.caption())
            .padding(Theme.spaceSM)
            .background(
              RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.card)
            )
        }
      }
      .padding(Theme.spaceLG)
      .spotifyScrollbar()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
    .fileImporter(isPresented: $showImporter, allowedContentTypes: [.javaScript, .plainText]) { result in
      do {
        let url = try result.get()
        _ = try api.importFromFile(url)
      } catch let e {
        error = e.localizedDescription
      }
    }
  }

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
}
