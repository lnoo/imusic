# iMusic（SwiftUI 原生 Spotify 深色版）

macOS 原生客户端，采用 **Spotify 深色设计语言（Encore 风格）** 打造，**源处理逻辑 1:1 复刻 `lx-music-desktop`**。
标准 Xcode macOS App 工程（macOS 27+，Swift 6）。

```bash
cd imusic
open iMusic.xcodeproj   # 打开后 ⌘R 运行 / ⌘. 调试
# 或命令行构建：
xcodebuild -project iMusic.xcodeproj -scheme iMusic -configuration Debug build
```

## 目录

```
iMusic/
  Models.swift            # MusicSource/Quality/MusicInfo/UserApiInfo（对标 common/types）
  SourceScriptParser.swift# parseScriptInfo/matchInfo + gz_+base64（对标 main/modules/userApi/utils.ts）
  UserApiStore.swift      # 导入/删除/选择/持久化（对标 UserApiModal + store.ts）
  UserApiEngine.swift     # JS 沙箱 lx.*（对标 renderer/preload.js + main.ts）
  SearchService.swift     # 搜索+榜单聚合（读 SourceRegistry，不写死源）
  SourceRegistry.swift    # 源能力注册表（对标 musicSdk/index.js；加新源只改此一处）
  Boards.swift            # kg/tx/wy/mg 真实榜单（对标各源 musicSdk/*/leaderboard.js）
  HomeView.swift          # 主页发现页（Hero/资料库总览/多源榜单/随心听/推荐，默认落地页）
  PlayerStore.swift       # 取URL/降级/AVPlayer（对标 core/music/online.ts + useInitUserApi）
  App.swift               # setUserApi 胶水（对标 core/apiSource.ts + useSettingSync）
  Views.swift             # 搜索/播放条/正在播放
  SourceSettingsView.swift# 设置-源管理 UI（对标 SettingBasic + UserApiModal + OnlineImportModal）
demo-source.js            # 可直接导入联调的最小源脚本
```

## 加新源（对标 musicSdk/index.js 注册表模式）

1. `Models.swift` `MusicSource` 加一个 case（如 `case bd`）；
2. `SourceRegistry.swift` `buildBuiltins()` 加一行 `SourceCapability`（搜索/榜单/歌词/封面/兜底按需填，不支持填 nil）；
3. 完成。搜索页芯片、主页榜单 Tab、换源/歌词/封面兜底、设置页能力一览全部自动出现。

`MusicInfo.source` 仍用 enum 做类型安全键；运行时分发一律走 `SourceRegistry`，不再写 `switch source`。

## 源处理逻辑对照（着重）

| 原项目 | 本项目 | 说明 |
|---|---|---|
| `common.apiSource`（默认 `temp`）+ `config_v2.json` | `UserDefaults(common.apiSource)`，默认 `temp` | 当前生效源 ID |
| `user_api.json`（`script = gz_+base64(deflate)`） | `~/Library/Application Support/iMusic/user_api.json` 同格式 | **与桌面端文件互通，可直接复制** |
| `utils.ts parseScriptInfo`：首段 `/* @name… */` 必填，截断 name24/desc36/author56/homepage1024/version36 | `SourceScriptParser.parseMeta` 逐行复刻 | 非法抛“无效的自定义源文件” |
| `importApi`：URL(`^https?://`，>9MB拒) / 本地 `.js`；压缩后全等去重；`id=user_api_<rand3>_<ts>`；上限20个 | `UserApiStore.importFromURL/importFromFile/importRawScript` | 行为一致 |
| `removeApi`：删当前选中回退 `backApi` | `UserApiStore.remove` 回退首个/或 `temp` | 一致 |
| 隐藏 `BrowserWindow` + `preload lx` + `executeJavaScript(script)` | `JavaScriptCore JSContext` + 注入 `lx` | 无 DOM；依赖 DOM 的脚本会初始化失败（与原项目 error 上报对齐） |
| `preload handleInit`：`allSources` + `supportQualitys` + `supportActions` 取交集；**非 local 默认只认 `musicUrl`** | `UserApiEngine.handleInited` 同表同逻辑 | 一致 |
| `lx.request`（needle，timeout≤60s，JSON尝试解析，返回cancel） | `URLSession` 实现，超时 `min(timeout,60s)`，可取消 | 一致 |
| `lx.utils.crypto/md5/aes/rsa/random + buffer + zlib + currentScriptInfo + version/env` | `md5✅ randomBytes✅ aes✅(CBC/ECB,128/256) buffer.from/bufToString✅ zlib✅ currentScriptInfo✅`；**`rsaEncrypt` 未实现**（MVP抛错） | 覆盖绝大多数源（网易 weapi 需 RSA 的源暂不支持） |
| `handleRequest` 校验：`musicUrl/pic` 须 `^https?` ≤2048；`lyric.lyric≤51200/t/r≤5120/lx≤8192`；请求 20s 超时；切源取消 | `callScript` 同校验 + 20s 超时 | 一致 |
| `useInitUserApi` 按 `actions` 动态生成 `getMusicUrl/getLyric/getPic` + `qualityList` | `engine.sources` + `PlayerStore.pickQuality`（高→低降级） | 一致 |
| 搜索/榜单直调官站，**不受自定义源影响** | `SearchService` 直调酷我 `search.kuwo.cn/r.s` + `handleResult` 归一化 | 先做 kw，kg/tx/wy/mg 可按同模式扩展 |
| `updateAlert`（log≤1024，一次） | `engine.onUpdateAlert` → 设置页弹窗 | 一致 |

## 源脚本协议（宿主已实现，脚本照旧写）

> 协议来源：[自定义源脚本编写说明](https://lxmusic.toside.cn/desktop/custom-source) + `preload.js` 源码。已用系统 JSC 实测文档范式（解构 `EVENT_NAMES/request/on/send` + 包裹后顶层 `await` + Promise 回传）全通。

```js
const { EVENT_NAMES, request, on, send } = globalThis.lx  // 必须有 EVENT_NAMES，本宿主已提供
lx.on('request', async ({ source, action, info }) => {
  // source: kw|kg|tx|wy|mg|local；action: musicUrl|lyric|pic
  // info: { type: '128k|320k|flac|flac24bit', musicInfo: {name,singer,source,songmid,albumName,types} }
  if (action === 'musicUrl') return 'https://...mp3'   // 必须 https? 开头，≤2048
  if (action === 'lyric') return { lyric: '...', tlyric, rlyric, lxlyric }
  if (action === 'pic') return 'https://...jpg'
})
await lx.send('inited', { sources: { kw: { type: 'music', actions: ['musicUrl'], qualitys: ['128k','320k'] } } })
await lx.send('updateAlert', { log: '...', updateUrl: 'https://...' }) // 可选，仅一次
// 可用：lx.request(url,{method,headers,body,form,formData,timeout},cb) / lx.utils.crypto.{md5,aesEncrypt,randomBytes}
//      lx.utils.buffer.{from,bufToString} / lx.utils.zlib.{inflate,deflate} / lx.currentScriptInfo / lx.version / lx.env
// 注意：lyric/pic 的 info 只有 {musicInfo}（无 type），musicUrl 的 info 为 {type, musicInfo}；与桌面端一致，本宿主照此发送。
```

实现细节（相对桌面端的两处适配）：

- `lx` 是挂在 `globalThis` 上的普通 JS 对象，支持文档式的解构写法；
- JavaScriptCore 的 `evaluateScript` 不支持顶层 `await`（实测报 SyntaxError），宿主自动把脚本包进 async IIFE 再执行，脚本写法不用改；

联调：设置 → 源管理 → 本地导入 `demo-source.js` → 生效源切到它 → 搜索 → 播放（走沙箱 `musicUrl`）。