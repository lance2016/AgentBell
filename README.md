# AgentBell

**几个 Claude Code 会话并行跑，也知道该切回哪一个。**

AgentBell 是一个原生 macOS 小工具。它把散在不同项目、分支和终端里的 Claude Code 会话收进一个面板。需要你确认时亮灯，点一下就回到现场。

![AgentBell 的粘土小终端，顶着一盏琥珀色状态灯](Resources/README/hero.webp)

## 一眼看状态，一键回现场

![AgentBell 的项目会话列表和会话详情，展示虚构项目 fern-studio 和 orbit-notes](Resources/README/sessions.webp)

*左边是按项目分组的会话列表，右边是选中会话的详情。截图来自应用界面，项目、分支和对话均为虚构。*

| 日常场景 | AgentBell 怎么帮你 |
| --- | --- |
| 同时盯几个项目 | 按项目分组或用侧栏浏览，置顶常用项目。用「待处理」集中看待确认和出错的会话，或按项目名、会话标题、分支搜索。 |
| 找回刚才那轮 | 点会话跳回原终端。打开详情可看最近对话、Git 分支和工作区改动。会话已结束时，可以复制恢复命令。 |
| 在另一个分支开工 | 从置顶项目、最近项目或任意文件夹新建 Claude Code 会话。有多个 Git worktree 时，可先选工作目录。 |
| 手头正忙 | 用菜单栏或桌面小终端看状态。待确认、出错、长回合完成时可收到系统通知或桌面气泡。长回合阈值可调。 |

Ghostty（1.4+）、iTerm2 和 macOS「终端」支持新建和精确跳回。Ghostty 与 iTerm2 还能定位到分屏。其他终端可切回应用。

## 桌面小终端

点小终端打开会话窗口。在「设置 → 桌面」可实时调整图标大小（64–128 pt，默认 88 pt），也可从图标的右键菜单直接打开「桌面设置」。

<img src="Resources/README/desktop-states.webp" width="480" alt="桌面设置页。待机为暖白灯和闭眼，工作中为蓝灯和二进制字流，等你确认为琥珀灯和问号，已完成为绿灯和对勾，出错为红灯和感叹号。">

*图为设置页的静态预览。桌面上工作时会滚动 `0` 和 `1`，完成时会短暂显示对勾。*

## 快速开始

需要 **macOS 14+**、**Xcode 16+（Swift 6）**，以及支持 `claude agents --json` 的 **Claude Code**。

```bash
git clone https://github.com/lance2016/AgentBell.git agent-bell
cd agent-bell
scripts/build-app.sh --install
```

1. 打开 AgentBell，点「连接」启用 Claude Code hooks。现有会话可以继续使用。
2. 需要通知时，点「允许通知」。第一次新建或跳回会话时，按 macOS 提示授权控制终端。
3. 想让跳回的分屏亮起边框，可在「设置 → 权限」里开启辅助功能。

菜单栏图标开关在「设置 → 通用」。面板内常用快捷键为 `⌘F` 搜索、`↩` 回终端、`⌘I` 看详情、`⌘C` 复制恢复命令。在任何地方按 `⌃⌥⌘J` 回到等你最久的会话，`⌃⌥⌘B` 打开面板，可在「设置 → 通用」里改。

## 数据留在本机

AgentBell 在本机读取会话列表、对话记录和 Git 状态，hook 事件通过本机 Unix socket 传递。应用只在启动或手动检查更新时请求 GitHub 的公开发布信息，点「下载并安装」时才下载新版本。

<details>
<summary>安装、连接与卸载细节</summary>

- `scripts/build-app.sh` 将应用打包到 `build/AgentBell.app` 并启动。加 `--install` 安装到 `/Applications`，加 `--no-launch` 跳过启动。
- 构建脚本优先使用钥匙串里的签名证书。使用临时签名时，重新构建后可能需要重新授权终端控制和辅助功能。
- 连接前会备份 `~/.claude/settings.json`，再注册 AgentBell hooks。仅靠轮询也能看到工作和空闲状态。待确认、完成和出错状态由 hooks 提供。
- 卸载时，先在「设置 → 通用」里点「断开」，再退出并删除应用。需要同时清除本地记录时，可删除 `~/Library/Application Support/AgentBell/`。

</details>

<details>
<summary>开发与排查</summary>

```bash
swift test
scripts/build-app.sh
swift scripts/make-icon.swift
```

用打包后的 `.app` 验证通知和 hooks。[架构设计](DESIGN.md) · [界面与交互](UI_DESIGN.md) · [更新记录](CHANGELOG.md) · [版本发布](https://github.com/lance2016/AgentBell/releases)

```bash
/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "com.agentbell.AgentBell"'
```

</details>
