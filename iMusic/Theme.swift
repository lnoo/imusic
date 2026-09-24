import AppKit
import SwiftUI

// MARK: - Spotify 深色设计系统
// 深色主题：墨黑画布 / 分层卡片 / 播放绿强调

enum Theme {
  // MARK: 颜色
  static let bg = Color(hex: 0x111311)        // 内容区背景
  static let sidebar = Color(hex: 0x090B0A)   // 侧栏背景
  static let card = Color(hex: 0x181B19)      // 卡片 / 播放条
  static let cardHover = Color(hex: 0x282C2A) // 卡片悬浮 / 描边
  static let navHover = Color(hex: 0x202420)  // 导航行悬浮
  static let accent = Color(hex: 0x1DB954)     // Spotify 绿（静止）
  static let accentHover = Color(hex: 0x1ED760) // Spotify 绿（悬浮/播放态提亮）
  static let text = Color(hex: 0xF4F7F5)       // 主文字
  static let text2 = Color(hex: 0xB7BDB9)     // 次级文字
  static let field = Color(hex: 0x232724)      // 搜索框底
  static let danger = Color(hex: 0xE45B68)     // 危险操作（删除/错误）

  static let rowHover = Color(hex: 0x252925)
  static let separator = Color(hex: 0x343934)
  static let scrollbar = NSColor(red: 0.95, green: 0.96, blue: 0.95, alpha: 0.28)

  // MARK: 圆角
  static let radiusCard: CGFloat = 8
  static let radiusRow: CGFloat = 6
  static let radiusCover: CGFloat = 6

  // MARK: 间距
  static let spaceXS: CGFloat = 8
  static let spaceSM: CGFloat = 12
  static let spaceMD: CGFloat = 16
  static let spaceLG: CGFloat = 24

  // MARK: 字阶（Spotify Mix 风格：标题特粗、正文紧凑）
  static func caption(_ weight: Font.Weight = .medium) -> Font {
    .system(size: 11, weight: weight)
  }
  static func body(_ weight: Font.Weight = .medium) -> Font {
    .system(size: 13, weight: weight)
  }
  static func bodySM(_ weight: Font.Weight = .regular) -> Font {
    .system(size: 12, weight: weight)
  }
  static func title(_ weight: Font.Weight = .bold) -> Font {
    .system(size: 16, weight: weight)
  }
  static func titleLG(_ weight: Font.Weight = .bold) -> Font {
    .system(size: 24, weight: weight)
  }
  static func display(_ weight: Font.Weight = .bold) -> Font {
    .system(size: 32, weight: weight)
  }
  static func monoCaption(_ weight: Font.Weight = .medium) -> Font {
    .system(size: 10, weight: weight, design: .monospaced)
  }

  // MARK: 通用组件样式
  /// 绿色圆形播放键（Spotify 灵魂组件）
  static func playButtonBG(enabled: Bool, hovered: Bool = false) -> some View {
    Circle().fill(!enabled ? cardHover : (hovered ? accentHover : text))
  }
  /// 次按钮描边（Spotify 灰边按钮）
  static func secondaryStroke() -> some View {
    RoundedRectangle(cornerRadius: radiusRow, style: .continuous)
      .stroke(separator, lineWidth: 1)
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1
    )
  }
}
