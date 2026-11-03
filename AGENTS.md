# AGENTS.md

## ⚠️ 硬性限制：`any-listen/` 为只读参考代码

`any-listen/` 是一个 **git submodule**（参考代码），仅作底层实现的参考用途：

- **不要对它做任何改变**：不修改、不新增、不删除、不重构其任何文件。
- **不要提交/修改该 submodule 内部的变更**（包括但不限于 `git add`、`git commit`、`git submodule update` 等对 submodule 内指针或内容的改动）。
- **它的作用只是参考**：本项目 `iMusic/` 内的 AnyListen 系列解析层、资源动作契约、数据模型等「严格对齐」`@any-listen/` 时，只允许**读取**它的源码作为参照，任何改动都必须落在本项目自己的文件里。

违反此限制的变更一律不予接受。

---

## 📁 官方扩展 submodule（`extensions/`）

`extensions/` 下是 any-listen 生态的 4 个官方扩展，作为 **git submodule** 直接纳入本项目，
供 iMusic 解析层/脚本引擎对照与联调。同样**只读、不改**（与 `any-listen/` 同等约束）：

| 目录 | 仓库 | 在 iMusic 中的定位 |
|---|---|---|
| `extensions/gdstudio` | Morpheus799/gdstudio-repo | GD音悦台：`AnyListenGD`/`musicUrl` 兜底的同源实现（music-api.gdstudio.xyz 端点/降级链/封面/歌词）|
| `extensions/online-metadata` | any-listen-extension-online-metadata | 在线元数据增强（曲目/专辑补充信息）|
| `extensions/lx-list-transform` | any-listen-extension-lx-list-transform | LX 音乐列表数据转换/导入 |
| `extensions/lx-api-source-loader` | any-listen-extension-lx-api-source-loader | LX 自定义源脚本加载器（对标 iMusic `UserApiEngine`）|

> 运行时在线播放：后三个联合使用达成完全效果，GD音悦台为功能增强。
> 这些扩展的运行态安装在 any-listen 的 `packages/web-server/data/app/extension/ext/`（由扩展商店运行时拉取），
> 此处作为 submodule 保留其**源码**以便 iMusic 侧参照，不承担运行时的安装职责。