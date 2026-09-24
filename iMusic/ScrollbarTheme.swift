import AppKit
import SwiftUI

// 原生 NSScroller 只提供 knobStyle（明/暗两档），没有取色 API，
// 唯一能改色的入口就是按官方推荐方式重写部件绘制方法。
// 这里只重画 knob，尺寸、淡入淡出、命中测试、拖拽全部交还 AppKit。

@MainActor
final class SpotifyScroller: NSScroller {
  /// 声明兼容 overlay，否则子类会被降级成 legacy 尺寸
  override class var isCompatibleWithOverlayScrollers: Bool { true }

  override func drawKnob() {
    let knob = rect(for: .knob)
    guard knob.width > 0, knob.height > 0 else { return }
    let bar = knob.insetBy(dx: knob.width / 4, dy: 0)
    Theme.scrollbar.setFill()
    NSBezierPath(
      roundedRect: bar,
      xRadius: bar.width / 2,
      yRadius: bar.width / 2
    ).fill()
  }

  /// Spotify 滑块无轨道底色
  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

// MARK: - 装到 SwiftUI ScrollView 的宿主 NSScrollView 上

@MainActor
private enum SpotifyScrollbarController {
  static func install(in scrollView: NSScrollView) {
    if scrollView.verticalScroller is SpotifyScroller { return }
    scrollView.hasVerticalScroller = true
    scrollView.verticalScroller = SpotifyScroller()
  }
}

@MainActor
private struct SpotifyScrollbarInstaller: NSViewRepresentable {
  func makeNSView(context: Context) -> InstallerView {
    let view = InstallerView()
    view.scheduleInstall()
    return view
  }

  func updateNSView(_ nsView: InstallerView, context: Context) {
    nsView.scheduleInstall()
  }

  final class InstallerView: NSView {
    private var pending: DispatchWorkItem?
    private var retries = 0

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      retries = 0
      scheduleInstall()
    }

    override func layout() {
      super.layout()
      scheduleInstall()
    }

    func scheduleInstall() {
      pending?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        guard let scrollView = self.enclosingScrollView else {
          // SwiftUI 的视图层级可能还没搭完，退避重试
          if self.retries < 40 {
            self.retries += 1
            self.scheduleInstall()
          }
          return
        }
        self.retries = 0
        SpotifyScrollbarController.install(in: scrollView)
      }
      pending = work
      DispatchQueue.main.async(execute: work)
    }
  }
}

extension View {
  /// 给纵向 ScrollView 换上 Spotify 配色的原生滑块
  func spotifyScrollbar() -> some View {
    background(SpotifyScrollbarInstaller())
  }
}
