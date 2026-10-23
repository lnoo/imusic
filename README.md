# iMusic（SwiftUI 原生 Spotify 深色版）

macOS 原生客户端，采用 **Spotify 深色设计语言（Encore 风格）** 打造，
**音源底层解析严格对齐 `any-listen` 的资源动作契约与数据模型**（搜索/歌单/榜单/歌词/封面），
自定义源脚本（LX 音源）通道保持 `lx-music` 系兼容。
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
  Models.swift            # MusicSource/Quality/MusicInfo/UserApiInfo（对标 any-listen MusicInfoOnline 映射）
  AnyListenResource.swift # any-listen 解析契约层：资源动作分发 + 归一化（br↔音质/去重/播放量）+ ALHttp/GD兜底
  AnyListenKw.swift       # 酷我解析：搜索/榜单/歌词(lrcx逐字解码)/封面/Secret签名 playUrl 兜底
  AnyListenKg.swift       # 酷狗解析：搜索(带封面)/56榜单目录/歌词(krc逐字解码)/歌单搜索+详情
  AnyListenTx.swift       # QQ解析：免签名搜索/榜单/歌单(标签+浏览+详情)/歌词(QRC三重DES解码)
  AnyListenWy.swift       # 网易解析：eapi搜索+明文兜底/歌单全链/榜单/歌词/热搜
  AnyListenMg.swift       # 咪咕解析：签名搜索/榜单/歌词(lrcUrl)/封面
  LyricCodec.swift        # 加密歌词解码：kg-KRC / tx-QRC(pyqdes) / zlib
  LyricService.swift      # LrcParser + OfficialLyric/OfficialPic（→ AnyListenResource 统一入口）
  SourceScriptParser.swift# parseScriptInfo/matchInfo + gz_+base64（对标 main/modules/userApi/utils.ts）
  UserApiStore.swift      # 导入/删除/选择/持久化（对标 UserApiModal + store.ts）
  UserApiEngine.swift     # JS 沙箱 lx.*（对标 renderer/preload.js + main.ts；对标 any-listen lx-api-source-loader）
  SearchService.swift     # 搜索+榜单聚合（读 SourceRegistry，不写死源）+ 歌单搜索状态 + 动态榜单目录
  SourceRegistry.swift    # 源能力注册表（对标 any-listen ResourceAction 宿主侧；加新源只改此一处）
  Boards.swift            # 主页榜单目录（静态兜底）+ HomeBoardFetcher（→ topSongsDetail 解析层）
  SonglistStore.swift     # 在线歌单浏览状态机：源/排序/标签 → 列表翻页 → 详情（wy/tx 浏览，kg 搜索）
  SonglistView.swift      # 歌单页 + 歌单卡片网格 + 歌单详情（复用 SongRow/PlayAllButton）
  HomeView.swift          # 主页发现页（随心听/动态多源榜单目录，默认落地页）
  AudioPulse.swift        # 随心听律动信号：AVAssetReader 旁路二次解码 + vDSP FFT 三频带 + 节拍检测（无音频落 104BPM 模拟律动）
  RandomListenMascot.swift# 随心听卡片视觉：Metal 律动 shader 背景 + 「流萤」2D 精灵宠物（播放小跑、随拍弹跳、切歌招手；素材见文件头致谢）
  Shaders.metal           # 卡片背景 fragment（渐变光斑 + 拍涟漪，随低/中/高频与响度律动，无噪声场）
  firefly_spritesheet.webp# 「流萤」精灵图集（8×9 行动作网格，CC BY-NC 4.0，作者 legeling)
  PlayerStore.swift       # 取URL/降级/AVPlayer（对标 core/music/online.ts + useInitUserApi）
  App.swift               # setUserApi 胶水（对标 core/apiSource.ts + useSettingSync）
  Views.swift             # 搜索/播放条/正在播放
  SourceSettingsView.swift# 设置-源管理 UI（对标 SettingBasic + UserApiModal + OnlineImportModal）
demo-source.js            # 可直接导入联调的最小源脚本
```

## 音源底层解析（严格对齐 any-listen）

契约与数据模型复刻自 `@any-listen/`（any-listen 仓库 `packages/shared/types`）：

- **资源动作**：`musicSearch / songlistTags·sorts·list·search·detail / topSongs·date·detail / musicLyric / musicPic / musicUrl`，
  入参与返回值形状与 any-listen `ResourceAction` 一致（`ListCommonResult{list,total,page,limit}`、`TopSongsItem{id,name,pic}`、`SongListItem{id,name,img,playCount,...}`）。
- **归一化**：br↔音质桥接（999/740/320/128 ↔ flac24bit/flac/320k/128k，GD音乐台同款）、歌手「、」连接、`mm:ss` 时长、按 id 去重。
- **加密歌词**：kg-KRC（XOR+zlib）、tx-QRC（pyqdes 三重 DES+zlib）、kw-lrcx（zlib+base64+"yeelion" XOR）在 `LyricCodec` 解码，均输出 原文/翻译/逐字(lxlyric)。
- **分工与 any-listen 生态一致**：app 内置直连解析负责 搜索/歌单/榜单/歌词/封面；播放直链主路径走 LX 自定义源脚本（= any-listen 的 lx-api-source-loader 定位），内置兜底走 `musicUrl`（kw 为官网 Secret 签名 playUrl，wy/tx 与 GD音乐台扩展同源接口）。
- **实测**：五源「搜索/歌单/榜单/歌词/封面」逐项实网验证全绿（见 git log 对应提交）。

## 界面能力（对标 any-listen 浏览体验）

- **歌单页**（侧栏「发现 → 歌单」）：来源切换（网易云/QQ）、排序与分类筛选、歌单卡片网格（封面/播放量/曲数）、
  详情就地切换（封面头图 + 播放全部 + 歌曲表）；搜索页「歌单」Tab 直达（wy/tx/kg 三源可切）。
- **榜单动态目录**：主页榜单卡来自 `topSongs()` 接口目录（kg 56 张 / tx 30 张，带榜图），
  静态目录作兜底；预取前 8 张，其余点进详情按需拉取；缓存 key 与旧版完全兼容。
- **逐字歌词**：kw-lrcx / kg-KRC / tx-QRC 解码出的词级时间轴在「正在播放」按 `currentTime` 逐字点亮，
  点任意词可跳播到该词起点；无逐字数据的源回退行级歌词。
- **OpenAPI 查询路由**（默认 33030，query 均已 percentDecode）：
  `/search?keyword=&source=`、`/songlist/search?keyword=&source=`、`/songlist/detail?source=&id=`、
  `/board?source=`、`/board/detail?source=&id=`、`/lyric?source=&songmid=`（kg 可附 `hash`/`secs`），
  返回 `{ok, list, info...}`；播放控制子集（/status /play /toggle…）保持原样。

## 加新源（注册表模式）

1. `Models.swift` `MusicSource` 加一个 case（如 `case bd`）；
2. 新建 `AnyListenBd.swift` 实现各资源动作；
3. `SourceRegistry.swift` `buildBuiltins()` 加一行 `SourceCapability`（按需填，不支持填 nil）；
4. 完成。搜索页芯片、主页榜单 Tab、换源/歌词/封面兜底、设置页能力一览全部自动出现。

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
| 搜索/歌单/榜单/歌词/封面解析 | `AnyListenResource` → 各源 `AnyListen*.swift`（any-listen 契约） | 五源全量；加密歌词内置解码 |
| 播放直链兜底 | `musicUrl`（kw 官网 playUrl 签名 / wy·tx GD音乐台同源降级链） | 主路径仍为自定义源 |
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