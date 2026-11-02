# AGENTS.md

## ⚠️ 硬性限制：`any-listen/` 为只读参考代码

`any-listen/` 是一个 **git submodule**（参考代码），仅作底层实现的参考用途：

- **不要对它做任何改变**：不修改、不新增、不删除、不重构其任何文件。
- **不要提交/修改该 submodule 内部的变更**（包括但不限于 `git add`、`git commit`、`git submodule update` 等对 submodule 内指针或内容的改动）。
- **它的作用只是参考**：本项目 `iMusic/` 内的 AnyListen 系列解析层、资源动作契约、数据模型等「严格对齐」`@any-listen/` 时，只允许**读取**它的源码作为参照，任何改动都必须落在本项目自己的文件里。

违反此限制的变更一律不予接受。