---
name: iMusic
description: 原生、克制的 macOS 音乐播放体验
colors:
  canvas: "#111311"
  sidebar-ink: "#090B0A"
  surface: "#181B19"
  surface-hover: "#282C2A"
  field: "#232724"
  text-primary: "#F4F7F5"
  text-secondary: "#B7BDB9"
  playback-green: "#1DB954"
  playback-green-hover: "#1ED760"
  danger: "#E45B68"
typography:
  display:
    fontFamily: "SF Pro Display, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "32px"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "SF Pro Display, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "24px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.015em"
  title:
    fontFamily: "SF Pro Text, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "16px"
    fontWeight: 700
    lineHeight: 1.3
  body:
    fontFamily: "SF Pro Text, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "13px"
    fontWeight: 500
    lineHeight: 1.45
  label:
    fontFamily: "SF Pro Text, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1.3
rounded:
  compact: "6px"
  card: "8px"
  artwork: "8px"
  control: "999px"
spacing:
  xs: "8px"
  sm: "12px"
  md: "16px"
  lg: "24px"
components:
  button-primary:
    backgroundColor: "{colors.playback-green}"
    textColor: "{colors.sidebar-ink}"
    typography: "{typography.body}"
    rounded: "{rounded.compact}"
    padding: "10px 16px"
    height: "40px"
  button-primary-hover:
    backgroundColor: "{colors.playback-green-hover}"
    textColor: "{colors.sidebar-ink}"
    rounded: "{rounded.compact}"
  button-secondary:
    backgroundColor: "{colors.surface-hover}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.compact}"
    padding: "10px 16px"
    height: "40px"
  input-standard:
    backgroundColor: "{colors.field}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.compact}"
    padding: "10px 12px"
    height: "40px"
  nav-active:
    backgroundColor: "{colors.surface-hover}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.compact}"
    padding: "8px 12px"
  random-listen-module:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-primary}"
    typography: "{typography.title}"
    rounded: "{rounded.card}"
    padding: "14px"
    width: "168px"
    height: "168px"
---

# Design System: iMusic

## 1. Overview

**Creative North Star: “安静的唱针”**

iMusic 是一台安静、可靠的 macOS 音乐播放设备。界面通过清晰的层级、熟悉的控件和克制的播放强调，把用户的注意力交给音乐，而不是装饰。深色环境适合长时间浏览与收听，所有关键状态都应自然地出现在用户视线需要的位置。

系统继承成熟音乐工具的内容可扫描性和标准控件预期，同时保持自己的产品身份。Spotify 文档只作为信息层级、封面呈现、元数据可读性和播放状态反馈的参考，不作为像素模板或品牌资产来源。

**Key Characteristics:**

- 原生优先，交互遵循 macOS 习惯。
- 平面深色层级，播放绿只服务于关键动作。
- 真实数据、真实状态、真实可播放反馈。
- 紧凑但不拥挤，标题和元数据快速可扫读。
- 键盘、VoiceOver、可见焦点和减少动态默认可用。

## 2. Colors

“墨黑与播放绿”建立安静、专注的播放环境。深中性色带轻微品牌色相，避免纯黑造成生硬边缘；播放绿承担开始播放、当前选择和关键确认。

### Primary

- **播放绿**：用于主播放按钮、当前电台和可操作的关键状态。不可用于大面积背景装饰。
- **播放绿悬停**：仅用于主按钮悬停或按下前的即时反馈。

### Neutral

- **画布墨色**：主页和主要内容区域的基础表面。
- **侧栏深墨**：应用导航和窗口级背景。
- **卡片炭色**：内容项、列表容器和浮层表面。
- **交互炭色**：悬停、选中与次级控件表面。
- **字段深灰**：输入框、搜索和过滤控件背景。
- **雾白文字**：标题、歌曲名和主要操作文字。
- **雾灰文字**：歌手、专辑、辅助说明和非活动元数据。
- **错误珊瑚红**：加载失败、不可播放和破坏性操作反馈。

**The 播放绿规则。** 播放绿只表达“可以播放、正在播放、当前选择或关键确认”。任何单个界面中的绿色面积不得超过约 10%，稀缺性是它的意义。

**The 真实状态规则。** 颜色永远与文字、图标或系统语义共同出现。禁止只用绿色表示成功，也禁止只用红色表示错误。

## 3. Typography

**Display Font:** SF Pro Display（系统回退为 -apple-system、BlinkMacSystemFont、sans-serif）
**Body Font:** SF Pro Text（使用同一系统回退链）
**Label/Mono Font:** SF Mono 仅用于技术标识和紧凑数值，不用于普通歌曲信息

**Character:** 单一系统字体家族提供熟悉的 macOS 质感。层级依靠固定字号和有限字重对比，不使用展示字体或装饰字体。

### Hierarchy

- **Display（700，32px）**：主页关键标题或极少数高价值内容，不进入常规卡片堆叠。
- **Headline（700，24px）**：页面级标题和重要状态标题。
- **Title（700，16px）**：区块标题、歌曲名和电台名。
- **Body（500，13px）**：按钮、导航和主要元数据。
- **Body Small（400，12px）**：歌手、专辑、时间和辅助说明。
- **Label（600，11px）**：紧凑状态、来源和计数信息，不使用全大写。

**The 音乐信息规则。** 歌曲名和电台名优先保持单行可识别，必要时允许用户查看完整文本。次级信息必须比主名称低一级，但不得使用低于清晰对比的灰色。

## 4. Elevation

系统采用原生平面层级。默认情况下不使用阴影表达结构，深度来自画布、侧栏、卡片和交互表面的明度差。阴影仅可用于真正脱离页面层级的临时浮层，并且保持轻量、低对比。

### Shadow Vocabulary

- **临时浮层**：短距离、低透明度的系统阴影，只在菜单、弹窗等短时界面使用。
- **无静态卡片阴影**：内容卡片在静止状态不使用阴影。

**The 平面优先规则。** 如果明度、间距和边框已经能够表达层级，就禁止再增加阴影、玻璃模糊或悬浮装饰。

## 5. Components

### Buttons

- **Shape：** 紧凑圆角（6px），图标与文字采用原生命中区域。
- **Primary：** 播放绿背景配深墨文字，标准高度 40px，内边距 10px 16px。
- **Hover / Focus：** 悬停仅提高绿色明度；键盘焦点使用系统可见焦点环，不通过阴影替代。
- **Pressed / Loading / Disabled：** 按下状态立即反馈；加载时保留按钮尺寸并更换为进度语义；禁用时同时降低明度并解释不可用原因。
- **Icon Button：** 播放、暂停、下一首、上一首和更多操作沿用系统 SF Symbol，并提供中文辅助功能标签。

### Chips

- **Style：** 使用交互炭色背景和小圆角，不使用高饱和标签。
- **State：** 未选中保持低对比，当前选择使用播放绿或明确选中标记；筛选和来源不能只靠颜色区分。

### Cards / Containers

- **Corner Style：** 内容卡片 8px，紧凑列表项 6px，大封面 8px。
- **Background：** 默认使用卡片炭色，不在每一层继续套卡。
- **Shadow Strategy：** 静止时无阴影。
- **Border：** 默认无装饰边框，必要时使用低对比分隔线。
- **Internal Padding：** 12px 至 16px，封面与文字间距 12px。

### Inputs / Fields

- **Style：** 深灰背景、6px 圆角、40px 标准高度，使用系统字体。
- **Focus：** 使用原生焦点环和可辨认边界，不使用发光边框。
- **Error / Disabled：** 错误信息紧邻字段并进入辅助功能树；禁用状态保留可读标签。

### Navigation

侧栏使用标准 macOS 导航节奏，图标和文字保持稳定对齐。当前页面使用克制的表面变化与文字强调，不增加侧边彩色条。窗口最小宽度下不压缩歌曲信息和主要操作。

### Random Listen Module

“随心听”是主页首要发现入口，呈现为一个方形卡片：一个图标、一个可点击面，没有标题行、来源切换、数量文案或并排按钮。候选池由热榜、历史与收藏去重构成，以随机模式在整个池上持续播放，不设抽取数量上限，也绝不暴露“已听 x/y 首”的队列进度；单曲结束后重新随机，队列听不完也不出现“播完”死路。卡片可见元素虽只有一个图标，仍必须给 VoiceOver 提供状态值（开始随机播放 / 正在准备 / 暂停 / 继续播放 / 重试）与原因，加载与失败用进度语义表达并配以文字，不靠颜色传达状态。键盘焦点使用系统可见焦点环，禁用态同时降低明度并在帮助文本中解释原因。

## 6. Do's and Don'ts

### Do

- **Do** 使用系统字体、SF Symbol、标准焦点环和原生控件行为。
- **Do** 用播放绿突出主操作、当前选择和已确认状态。
- **Do** 保持歌曲名、歌手、专辑和来源真实，并允许用户查看被截断的完整信息。
- **Do** 为加载、播放、暂停、失败、空数据和不可播放提供文字与图标双重反馈。
- **Do** 用平面深色表面、清晰间距和有限字重建立层级。
- **Do** 让键盘、VoiceOver、减少动态效果和最小窗口尺寸成为完成标准。

### Don't

- **Don't 像素级复制 Spotify 页面或使用 Spotify 标识、商标及品牌组合。**
- **Don't 用假歌曲、假榜单、占位统计或空壳推荐填充“随心听”。**
- **Don't 用大量同尺寸卡片、过度圆角、装饰性渐变或动效制造热闹感。**
- **Don't 让卡片文案承诺与实际队列、播放模式或可用音源不一致。**
- **Don't 只在图标或颜色中表达播放状态，不提供可访问的文字反馈。**
- **Don't 为了视觉一致性隐藏音源失败、加载中和不可播放等真实状态。**
- **Don't** 覆盖或变形原始封面，不把控制按钮、渐变或文字压在封面上。
- **Don't** 使用纯黑、纯白、玻璃拟态、侧边彩色条、渐变文字或以布局属性制作动画。
