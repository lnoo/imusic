import SwiftUI
import AppKit

// MARK: - 封面动作层（复制 / 下载到本地）
//
// 正在播放页封面浮层（CoverActionsOverlay）是唯一 UI 入口；本层只管数据与系统交互：
//   复制：拉原始字节 → NSImage 上剪贴板（TIFF 无损，Preview/微信/Keynote 通用）
//   下载：NSSavePanel 选位置，按原始格式落盘（魔数识别 jpg/png/webp/gif 扩展名）
// 封面 URL 由调用方给（现在播放页传 player.current?.picUrl，缺失时 PlayerStore 已兜底回填）。

enum CoverImageActions {

  enum Outcome {
    case done, cancelled, failed

    /// 是否值得给用户反馈（下载面板取消不打扰）
    var showsFeedback: Bool { self != .cancelled }
  }

  /// 复制封面图片到剪贴板
  @MainActor
  static func copyToPasteboard(_ urlString: String) async -> Outcome {
    guard let data = await fetch(urlString), let image = NSImage(data: data), image.size.width > 0 else {
      return .failed
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    return pb.writeObjects([image]) ? .done : .failed
  }

  /// 封面存储为…（NSSavePanel 选位置；用户取消返回 .cancelled）
  @MainActor
  static func saveAs(_ urlString: String, suggestedName: String) async -> Outcome {
    guard let data = await fetch(urlString) else { return .failed }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    panel.message = "选择封面图片的保存位置"
    panel.nameFieldStringValue = "\(sanitized(suggestedName)).\(fileExtension(of: data, urlString: urlString))"
    guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }
    do {
      try data.write(to: dest, options: .atomic)
      return .done
    } catch {
      return .failed
    }
  }

  // MARK: 内部

  /// 拉取原始字节（带 UA：部分图床校验；与 ALHttp 同款）
  private static func fetch(_ urlString: String) async -> Data? {
    guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
    return data
  }

  /// 魔数识别图片格式；URL 扩展名兜底，默认 jpg（音乐封面绝大多数为 jpeg）
  private static func fileExtension(of data: Data, urlString: String) -> String {
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if data.count > 12, data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WEBP".utf8) {
      return "webp"
    }
    if data.starts(with: Data("GIF8".utf8)) { return "gif" }
    switch URL(string: urlString)?.pathExtension.lowercased() {
    case "png": return "png"
    case "webp": return "webp"
    case "gif": return "gif"
    default: return "jpg"
    }
  }

  /// 文件名清洗（与 DownloadStore 同规则：/ 与 : 换全角）
  private static func sanitized(_ name: String) -> String {
    let cleaned = name
      .replacingOccurrences(of: "/", with: "、")
      .replacingOccurrences(of: ":", with: "：")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "封面" : cleaned
  }
}

// MARK: - 封面动作浮层（hover 显形；复制/下载两枚小圆钮 + 结果反馈）
//
// isHovered 由父级封面容器给（hover 覆盖整张封面，指针进出按钮不闪隐）。
// 浮层自带 busy/反馈态：进行中转圈，成功 ✓（播放绿）/ 失败 ✗（珊瑚红），1.4s 后复原；
// 同时在整张封面挂右键菜单，动作与按钮共用同一份状态。VoiceOver 恒可见（不随 hover 隐藏）。

struct CoverActionsOverlay: View {
  var urlString: String?
  /// 复制/下载的默认文件名（不含扩展名，扩展名按图片真实格式补）
  var suggestedName: String
  var isHovered: Bool
  var buttonSize: CGFloat = 28

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private enum Action: Equatable {
    case copy, save
  }

  /// 一次性反馈标记（带 UUID：延迟清场时只清自己那一次，防串）
  private struct FeedbackMark: Equatable {
    let action: Action
    let ok: Bool
    let id = UUID()
  }

  @State private var busy: Action?
  @State private var feedback: FeedbackMark?

  var body: some View {
    ZStack(alignment: .topTrailing) {
      // 整张封面接收右键，菜单项与按钮共用 busy/反馈状态
      Color.clear
        .contentShape(Rectangle())
        .contextMenu { menuItems }

      HStack(spacing: 6) {
        actionButton(.copy)
        actionButton(.save)
      }
      // 不可见时不可点（SwiftUI 的 opacity(0) 仍参与命中）
      .allowsHitTesting(isHovered && busy == nil)
    }
    .opacity(isHovered ? 1 : 0)
    .scaleEffect(isHovered ? 1 : 0.94, anchor: .topTrailing)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
  }

  @ViewBuilder private var menuItems: some View {
    Button("复制封面图片") { perform(.copy) }
    Button("封面存储为…") { perform(.save) }
  }

  private func actionButton(_ action: Action) -> some View {
    Button { perform(action) } label: { actionIcon(action) }
      .buttonStyle(.plain)
      .disabled(busy != nil)
      .help(action == .copy ? "复制封面到剪贴板" : "封面保存到本地…")
      .accessibilityLabel(action == .copy ? "复制封面图片" : "下载封面到本地")
  }

  @ViewBuilder private func actionIcon(_ action: Action) -> some View {
    let mark = feedback
    let isMarked = mark?.action == action
    ZStack {
      Circle().fill(.black.opacity(0.55))
      Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1)
      if busy == action {
        // 加载保留按钮尺寸，换进度语义（DESIGN.md 按钮规范）
        ProgressView().controlSize(.mini)
      } else if isMarked, let mark {
        Image(systemName: mark.ok ? "checkmark" : "xmark")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(mark.ok ? Theme.accent : Theme.danger)
      } else {
        Image(systemName: action == .copy ? "doc.on.doc.fill" : "arrow.down.to.line")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
      }
    }
    .frame(width: buttonSize, height: buttonSize)
  }

  private func perform(_ action: Action) {
    guard let urlString, !urlString.isEmpty, busy == nil else { return }
    busy = action
    Task {
      let outcome: CoverImageActions.Outcome
      switch action {
      case .copy: outcome = await CoverImageActions.copyToPasteboard(urlString)
      case .save: outcome = await CoverImageActions.saveAs(urlString, suggestedName: suggestedName)
      }
      busy = nil
      guard outcome.showsFeedback else { return } // 下载面板取消：不打扰
      let mark = FeedbackMark(action: action, ok: outcome == .done)
      feedback = mark
      Task {
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        if feedback == mark { feedback = nil }
      }
    }
  }
}
