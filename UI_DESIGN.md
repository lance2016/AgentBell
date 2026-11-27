# AgentBell 界面设计

界面以本文为准。`DESIGN.md` 第 3.6 节的草图只说明有哪些内容。

依据两套规则：Apple HIG（本文标「HIG」的是 Apple 的指引，标「解读」的是我们按它做的取舍）和 unslop（安静的外框，颜色和细节只留给一两处）。

## 1. 方向

- **产品：** 给同时开着好几个 Claude Code 的开发者，常驻菜单栏，告诉你哪个会话在等你、哪个做完了，点一下回到那个终端。
- **性格：** 安静、准确、有分寸。平时几乎看不见，要你出手时一眼就看到。
- **世界：** 值班台上的指示灯。整面板是灰的，只有该亮的那盏灯亮。
- **亮点：** 两处。一是"等你"那一行：琥珀色的灯，加上 Claude 想做什么的那句话。二是应用图标：一块深色的终端小方块，右上角一盏琥珀灯。
- **签名细节：** 状态灯。菜单栏图标、每一行会话、应用图标、设置里的连接状态，用的都是同一套灯，别处不加别的装饰。

**模板检查：** 把名字换成别的产品，这套界面还说得通吗？说不通。灯、终端方块、"想改 PetSpeech.tsx，等你点头"这类句子，都只属于它。

## 2. 视觉基础

### 2.1 颜色

外框全部用系统颜色，跟随浅色、深色和"增强对比度"（HIG：语义颜色按角色用）。

| 角色 | 取值 |
|---|---|
| 面板底 | 系统弹出层材质（`NSVisualEffectView` 的 `.popover`），不自己画底色 |
| 主文字、次文字、弱文字 | `labelColor`、`secondaryLabelColor`、`tertiaryLabelColor` |
| 分隔线 | `separatorColor` |
| 悬停 | 主文字色 6% |
| 选中（侧栏里的项目、键盘移到的行） | 强调色 14%，选中项目的个数也用强调色；键盘操作时加系统焦点环。不用绿色，绿色只表示"做完" |
| 强调色 | 低饱和的紫：浅色 `#6B5FC7`，深色 `#B2A8F2`。只用在选中状态和会话行的任务标签上 |
| 开关、按钮 | 系统强调色（用户在系统设置里选的颜色），不自定义。「新建会话」是页面上唯一的实心按钮（`.borderedProminent`）。例外是会话详情的主按钮：浅色用石墨色 `#3A3A3C`，深色用白色 tint（AppKit 会画成比普通按钮亮一档的灰），这样页面上有颜色的只剩灯 |
| 文字链接（刷新、加载更早的对话） | 次文字色，悬停时出底色。不用系统链接样式，因为它是强调色 |

产品自己的颜色只有状态灯。只用在灯和极少的状态字上：

| 灯 | 浅色 | 深色 | 用作文字时 |
|---|---|---|---|
| 等你（琥珀） | `#F5A524` | `#F5A524` | 浅色 `#9A5B00`，深色 `#F0B34A` |
| 做完（绿） | `#2F9E62` | `#4CC38A` | 不用作文字 |
| 出错（红） | `systemRed` | `systemRed` | `systemRed` |

不用渐变、发光、彩色阴影。紫色只作上面说的强调色，不用在灯和状态字上。

**图标方块**（照系统设置）：侧栏每一项前面一个 20pt 的圆角方块，纯色底、白色 SF Symbol，不加渐变。方块说明"这是什么"，从不表示状态，状态只看灯。

| 项 | 颜色 | 图标 |
|---|---|---|
| 待处理 | `systemBlue` | `tray.fill` |
| 开发任务 | `systemGray` | `chevron.left.forwardslash.chevron.right` |
| 项目 | 按项目路径固定取一种：`systemIndigo`、`systemPurple`、`systemPink`、`systemTeal`、`systemBrown`（避开灯的琥珀、蓝、绿、红），每次启动都一样 | `folder.fill` |

只剩已关闭会话的项目，方块降到 50% 不透明度。列表模式的分组名前也是它；右边的标题前不放，标题已经写了名字。

数字：没选中时是次文字色的数字；选中的项是强调色实心胶囊、白字；「待处理」有内容时是 `systemRed` 实心胶囊、白字，和系统设置的"有软件更新可用"一样。

### 2.2 状态灯

灯本身直径 8pt，放在 16pt 宽的列里居中。光看颜色分不出状态的用户，靠形状加旁边的状态字也能分清（HIG：不只靠颜色传达信息）。

| 状态 | 形状 | 状态字 |
|---|---|---|
| 等你 | 琥珀实心圆 | 等你 |
| 在工作 | 灰色细圆环，上面一段 90° 的弧在慢慢转（1.2 秒一圈）；开了"减弱动态效果"就不转 | 在工作 |
| 后台在跑 | 灰色虚线圆环 | 后台在跑 |
| 做完 | 绿色实心圆 | 做完 |
| 出错 | 红色实心圆，中间一道白色短竖线 | 出错了 |
| 空闲、已打断 | 弱文字色细圆环 | 空闲、已打断 |
| 已结束 | 弱文字色细圆环，整行降为弱文字色 | 已结束 |

只有"在工作"会动，因为它确实是活的状态。别的灯都不闪、不呼吸。

### 2.3 字体

系统字体：SF Pro 做界面，SF Mono 做时间、分支和命令。不引入别的字体（HIG：优先用系统文字样式）。

| 用途 | 字号/行高 | 字重 |
|---|---|---|
| 面板标题（应用名、项目名、"搜索""待处理"） | 15 | 600 |
| 详情页的会话名 | 17 | 600 |
| 项目分组名、详情页卡片标题 | 13 | 600 |
| 会话名 | 13 | 500 |
| 状态说明（第二行）、按钮文字 | 12 | 400 |
| 时间、数量 | 11，等宽数字 | 400，次文字色 |
| 分支 | 11 SF Mono | 400，次文字色，不加底色 |

字重只用 400、500、600，层级主要靠字号和颜色。

句子格式，不用全大写加宽字距的标签；不用斜体；短句结尾不加句号。

### 2.4 间距和圆角

4pt 网格。面板左右内边距 12，项目分组之间 12，分组名到第一行 4。

| 元素 | 尺寸 |
|---|---|
| 面板 | 列表宽 400，侧栏宽 600，高 520，超出的部分滚动 |
| 小控件（返回、搜索、待处理、设置、退出、搜索框） | 高 28，圆角 6 |
| 行内按钮（行尾 ⓘ、项目行悬停时的 + 和图钉） | 24×24，圆角 6 |
| 会话行、侧栏项目 | 上下内边距 8；侧栏项目高 34；悬停、选中底圆角 8，左右各缩进 4 |
| 卡片 | 圆角 12 |

### 2.5 图标

线条图标只用 SF Symbols，`regular` 字重，统一 12pt，颜色跟着所在文字的颜色；顶栏按钮里的图标 13pt。展开箭头 `chevron.right` 统一 10pt `semibold`。

图标只放在有用的地方：侧栏各项和分组名前的图标方块（见 2.1；置顶的项目也是文件夹，图钉在行尾）、「已关闭」前的时钟、按钮、右键菜单。会话行左边只有那盏灯，行尾一个 ⓘ；代码审查会话在灯和标题之间多一个 `text.magnifyingglass`（次文字色），说明会话的种类，不是状态。详情页的卡片标题和信息行不放图标。

## 3. 菜单栏图标

**解读：** 菜单栏图标用模板图，跟随菜单栏的明暗（HIG：菜单栏附加项用符号或模板图）。

图形是一个 16×16pt 的圆角终端方块（描边 1.5pt，圆角 3.5pt），左下角一个 `›` 提示符，右上角一盏 5pt 的灯，灯的位置稍微压出方块的边。

| 整体状态 | 灯 | 图标右边 |
|---|---|---|
| 没有会话，或都空闲 | 空心 | 无 |
| 有会话在工作 | 实心（模板色） | 无 |
| 有会话等你 | 琥珀实心 | 等你的个数，12pt 等宽数字 |
| 有会话出错、你还没看 | 红色实心 | 无 |

- 菜单栏图标永远不动。"在工作"也只是实心灯，不转（**解读**：菜单栏里一直在动的东西太分心）。
- 琥珀灯和红灯不是模板色，要准备浅色和深色菜单栏两套。
- 数字让"等你"不只靠颜色表达。
- 左键打开面板。右键弹出小菜单：打开面板、设置…、退出。

## 4. 面板

点菜单栏图标弹出，锚定在图标下方（HIG：弹出层轻量、锚定在触发它的地方）。面板里没有要编辑的内容，所以点外面直接收起。在全屏应用上方也能显示。

### 4.1 结构

```
┌────────────────────────────────────────────┐
│ 1 个等你 · 1 个在工作                        │  标题行 40
├────────────────────────────────────────────┤
│ ai-pet                              main   │  分组名
│ ●  修复提醒按钮挤在一起          等你  3 分  │
│    想改 PetSpeech.tsx，等你点头      ↩       │  选中时末尾出现键帽
│ ◔  加使用统计页                在工作 12 分  │
│    运行测试                                │
│                                            │
│ robot                       feat/pid-tune  │
│ ●  重写电机驱动                  做完  刚刚  │  绿灯
│    已把 PID 参数改成可配置，测试全部通过      │
│                                            │
│ api-gateway                         main   │
│ ●  排查网关偶发 502             出错了  2 分  │  红灯
│    额度用完了                               │
├────────────────────────────────────────────┤
│ 已关闭 3                                 › │  一行，点开就地展开
├────────────────────────────────────────────┤
│ 设置…  ⌘,                        退出  ⌘Q  │  页脚 36
└────────────────────────────────────────────┘
```

### 4.2 标题行

- **列表：** 左边是应用图标和"AgentBell"（面板也能以窗口打开，这时需要名字），右边是搜索按钮和「新建会话 ⌄」。
- **侧栏：** 项目名是普通标题，不能点；分支写在每一行上，标题里不写。再往右一句状态，只写待确认、出错和在工作的数量，都没有就省略。右边是「新建会话 ⌄」。
- **详情：** 左边是返回按钮"‹ 项目名"。
- 「新建会话」带文字和下拉箭头，点开选在哪个项目里新建：置顶项目、最近项目、选择文件夹…。这是唯一常驻的新建入口，项目行上不再放 `+`。
- 项目自己的操作（新建会话、置顶、在访达中显示）都在项目行上：图钉在行尾：置顶后常驻，没置顶的悬停时才出现，点它切换；左边始终是文件夹。右键菜单三项都有。悬停的底色铺满整行，图钉也在底色里。标题上不再放菜单。

### 4.3 分组和排序

- 按项目文件夹分组，分组名就是文件夹名。分支写在每一行上，分组名旁边不写：会话可以各在各的分支和 worktree 里。
- 有会话等你的项目排最前，然后是在工作的，然后是其余的，同一档里最近有动静的在前。组内先排等你的（等得最久的在前），再排在工作的，其余的按最近一次动静排，最近的在前。
- "动静"只算状态切换（开始一轮、做完、出错、结束），不算每次工具调用，所以一轮跑着的时候行不会跳。换位置时有 200ms 的过渡（见 §9）。

### 4.4 会话行

- **第一行：** 灯、代码审查图标（只有审查会话有）、会话名（13pt 600，行里最显眼；Claude 自己起的标题；没有就用这一轮提问的第一行；一行放不下就截断）、右对齐的用时。已结束的会话名用 500 和次文字色。
- **第二行：** 最近一轮的摘要，只占一行，放不下截断，次文字色。等你时写想做什么（"想改 PetSpeech.tsx，等你点头""有话问你""写好计划了，等你过目"），用琥珀文字色；工作时写当前活动；做完时写回复的第一行；出错时写原因。只剩状态字（"在工作""空闲"）又不需要你处理时，改写这一轮问了什么，前面加弱文字色的"你："。会话列表本身宽 520 以上时（会话窗口，不是 600 宽的面板），摘要分两行：先是"你："加这一轮问了什么，再是上面这句；两句里有一句什么都不多说（只剩状态字、或问的就是标题）时，仍然只写一行。按列表的实际宽度判断，不按排列方式判断。
- **第三行：** 辅助信息，有才出现，一个都没有就不占这一行：项目名（跨项目的「待处理」页）、分支（每一行都写，按会话自己的目录读）、worktree（会话在自己建的 worktree 里时写目录名）、加入的未完成开发任务。代码审查会话的检出是游离 HEAD，分支那里改写"源分支 → 目标分支"（开始审查时记在检出旁的 `review.json` 里；更早的检出没有这个文件，就不写分支），也不写 worktree。已关闭的行只有名字和时间。都是 18pt 高的小标签；项目和分支是中性浅底次文字色，任务用强调色。不画没有数据来源的状态或分类。
- **用时：** 不到 1 分钟写"刚刚"，然后是"3 分""1 小时 5 分"。
- **点一行：** 回到终端。行尾一个 ⓘ 按钮（平时很淡，悬停时变深），点它打开这个会话的详情，见 4.10。
- **已结束的会话**没有终端可以回，点了就复制 `claude --resume <id>`，状态说明那一行临时变成"已复制恢复命令"，1.5 秒后还原。
- **行尾：** 用时后面是铅笔（重命名），再后面是 ⓘ（详情），最后是 ⊗（关闭会话，只有开着的会话有）。铅笔常驻，弱文字色，悬停变深并出底色。⊗ 只在悬停或选中这一行时出现，位置一直留着，行不会跳；免得点 ⓘ 时误点到它。标题过长时截断标题，不挤用时和这些按钮。
- **关闭会话：** 先弹确认框，标题"关闭「会话名」？"，说明"会结束这个会话的 Claude 进程，正在进行的这一轮会中断。对话会保留，之后可以用 claude --resume 恢复。"，按钮「关闭会话」（破坏性）和「取消」（HIG：难以撤回的破坏性操作先确认）。确认后状态说明那一行临时写"正在关闭…"，下一次刷新时这一行移进「已关闭」；进程核对不上时写"没能关闭：找不到这个会话的 Claude 进程"。
- **右键菜单：** 回到终端、复制恢复命令、在访达中显示、重命名…，开着的会话最后还有分隔线下的「关闭会话…」。前三件事也都能用键盘做，重命名在行尾的铅笔上（HIG：右键菜单里的命令在主界面里要有别的入口）。
- **重命名：** 行里和详情里都是就地改：标题换成输入框（自动聚焦、全选原名），右边一个强调色的 ✓ 保存、一个中性的 ✕ 取消。回车保存，Esc 取消。首尾空格去掉；空名字不能保存；没改就直接收起，不写文件；把会话自己原来的标题改回去，等于去掉 AgentBell 起的名字。先写文件、写成功才换名字，失败时保留原名，在输入框下面用红字说明。行里改名时不进详情，行高不变，点输入框不会回到终端；详情里改名时主按钮不响应回车。详情标题右边也有同样的铅笔；「···」菜单里不再放重命名。名字只存在 AgentBell 里（`titles.json`，按会话 id），会话关掉、被清出「已关闭」、再 `claude --resume` 回来都还在；Claude Code 没有外部改名的接口，所以终端和 `claude --resume` 列表里的名字不变。
- **标题的来源：** AgentBell 里起的名字，然后是 `/rename` 的名字（开着时来自 `claude agents`，关掉后来自对话记录里的 `custom-title`），然后是代码审查会话的"审查 源分支"（旧检出写"代码审查"；审查用 `-p` 跑，Claude 不会起标题），然后是 Claude 自己的标题，最后是这一轮的提问。AgentBell 发出的审查提示词不算你的提问，不出现在"你："那一行。
- **悬停：** 只换底色，不位移、不放大。
- **跳转失败**（终端已经关了）：第二行临时显示"找不到这个终端，已复制恢复命令"。

### 4.5 「已关闭」

会话退出后收进「已关闭」，默认折叠成一张单独的卡片，一行标题后面写个数。点开就在原地展开，行高 32，只显示会话名和时间。最多保留 24 小时。侧栏模式下也一样：开着的会话在一张卡片里，「已关闭」在它下面另一张卡片；项目里没有开着的会话时，「已关闭」直接展开，不能折叠。

### 4.6 页脚

左边"设置…"，右边"退出"。都是普通文字按钮，次文字色，快捷键 `⌘,`、`⌘Q` 写在悬停提示里。

### 4.7 键盘

| 按键 | 作用 |
|---|---|
| ↑ ↓ | 在会话之间移动 |
| ← → | 侧栏模式下切换项目 |
| ↩ | 回到终端 |
| ⌘I | 打开选中会话的详情 |
| ⌘C | 复制选中会话的恢复命令 |
| ⌘, | 打开设置 |
| Esc | 先关详情，再收起面板 |
| ⌘Q | 退出 |

全局快捷键在「设置 → 通用 → 快捷键」里改，按 Delete 关掉：

| 默认 | 作用 |
|---|---|
| ⌃⌥⌘B | 打开面板，再按一次收起 |
| ⌃⌥⌘J | 回到等你最久的会话；没有等你的就去最近出错的；都没有就打开面板 |

面板打开时，焦点停在第一个"等你"的会话上；没有的话，停在第一行。

### 4.8 各种状态

| 状态 | 面板显示 |
|---|---|
| 还没连接 Claude Code | 中间一盏空心的灯（32pt）。下面一行主文字"连接 Claude Code 后，这里会列出你的会话"，一行次文字"会在 ~/.claude/settings.json 里加几条只读的钩子，改之前先备份"。主按钮"连接"，次按钮是文字链接"会改动什么" |
| 找不到 `claude` | 同样的版式。文字"没找到 Claude Code"，次文字写找过哪些位置，按钮"手动选择…" |
| 已连接，但没有会话 | 一行次文字"没有在跑的会话"，下面一行弱文字"在终端里运行 claude 就会出现在这里" |
| 钩子要重连（应用挪了位置） | 列表照常显示，标题行下面一条细提示条："钩子指向的位置变了，提醒可能收不到"，加一个"重新连接"文字按钮 |
| Ghostty 版本太旧（选的终端是 Ghostty，版本低于 1.4.0） | 标题行下面一条细提示条："Ghostty 1.3.1 太旧，需要 1.4.0 或更新"，加一个"更新"文字按钮，打开 Ghostty 下载页。每次打开面板时检查，更新后自动消失 |
| 通知没有授权 | 页脚上方一条细提示条："通知已关闭，等你确认时不会提醒"，加一个"打开系统设置"文字按钮 |

提示条最多同时显示一条，按上面表格的顺序取第一条。

### 4.9 两种排列

在设置的「通用」里选，默认「列表」。

- **列表：** 宽 400，按项目分组排成一列，就是上面几节写的样子。会话少时一眼看全。
- **侧栏：** 宽 600，照系统设置的样子分左右两栏。左边 200 宽，从顶到底：窗口里是红绿灯，然后是常驻的搜索框（输入就开始搜，Esc 或 ✕ 结束），再是项目，最底下"设置…"和退出。每个项目左边是图标方块，行尾一盏灯：有人等你是琥珀灯，出错是红灯，有会话在跑是转圈，都空闲就不亮；再后面是开着的会话数；只剩已关闭会话的项目名字变淡，排在最后。侧栏顶上不放会话总数，每个项目自己的灯已经说清楚了。右边顶上一行是标题：项目名加一句状态，右边是「新建会话」；下面是它的会话，已关闭的折叠成"已关闭的 N 个会话"。详情也在右边打开，侧栏不动。面板打开时选中有人等你的项目。

### 4.10 会话详情

点 ⓘ 或按 ⌘I，详情就地替换列表，不另开窗口。从上到下：

- **头部：** 返回按钮（"‹ 项目名"）、会话名、状态灯加"状态词 · 多久前"。只有等你、在工作、后台在跑、出错时，下面才多一行说明（想做什么、在做什么、为什么出错）；其他状态这一行就是上一轮的回复，下面"最近一轮"已经有了，所以不显示。
- **按钮：** 只有三个。主按钮（会话开着是「回到终端」，结束了是「复制恢复命令」，回车触发）、「加入任务」菜单、`···` 菜单。复制恢复命令（会话开着时）、复制带 `cd` 的恢复命令、复制会话 ID、复制目录、在访达中显示都在 `···` 里，开着的会话最后还有「关闭会话…」。两个菜单都不显示下拉箭头。
- **Tab：** 概览、对话、改动。复制成功之类的提示放在 tab 这一行的右边，出现和消失都不推动下面的内容。
- **概览：** 四张卡片。「最近一轮」：你的提问加回复，回复最多 6 行，底下「查看全部对话」。「开发任务」：这个会话所在的任务，每行是任务名加状态，点一下打开任务；没加入时写"还没有加入任务"。「工作区」：位置（worktree、主仓库或代码审查检出）、目录、审查范围（只有审查会话有，"源分支 → 目标分支"）、分支和领先/落后、改动文件数（点一下进「改动」）、最近提交。「会话信息」：会话 ID、开始时间、时长。

最近几轮优先用钩子记下的（每开始新一轮，就把上一轮的提问和结果收起来，最多 5 轮，重启不丢）；没有钩子记录时，从会话记录末尾读；再没有，就只显示最近一次的提问和回复。会话记录末尾常常全是工具输出和截图，读不到提问，所以钩子记录排在前面。

### 4.11 开发任务

一个功能做到一半被打断，回来时要知道代码在哪个分支、会话在哪、下一步做什么。

- **入口：** 侧栏里「待处理」下面一行「开发任务」，后面是未完成的任务数；这两页和下面的项目之间隔一条分隔线；列表模式在状态行右边，「待处理」旁边一个「任务」按钮。
- **页面：** 标题「开发任务」，右边「新建任务」。够宽（内容区 ≥ 560）时分两栏：左边任务列表和搜索框，右边选中任务的详情；不够宽时先列表，点进去看详情，「‹ 全部任务」或 Esc 返回。
- **新建：** 「新建任务」在列表顶上出一个输入框，只填标题、回车就保存，Esc 取消。
- **列表：** 进行中在前，然后待做，已完成在最后并划掉；同一档里新建的在前。编辑不改顺序。第二行写工作区个数。搜索只看任务名、项目名和分支。
- **详情：** 标题，下面是「状态」弹出按钮（系统 pop-up，待做／进行中／已完成，当前值打勾）。HIG 把互斥的几个状态交给 pop-up 按钮；不用 pull-down 菜单（那是放命令的），也不用分段控件（和详情里的「概览／对话／改动」长得一样，看着像切换视图）。「下一步」最显眼，左边一道强调色竖线（不用绿色，绿色只表示做完）；下面是「说明」；最后是工作区卡片。所有字段原地编辑，边打边存。
- **工作区：** 每行写项目名、分支、目录。会话还开着：状态灯加"会话仍在运行"，按钮「回到终端」，跳转逻辑和会话行相同；会话已关闭：弱灰灯加"会话已关闭"，按钮「复制恢复命令」，复制的是 `cd <目录> && claude --resume <id>`。右键还有复制目录、在访达中显示、移除工作区。
- **从会话加入：** 会话详情的按钮行和会话行的右键菜单都有「加入任务」：新建任务（以会话标题命名，状态进行中，打开后标题可直接改），加入已有的未完成任务，或跳到它已经在的任务。同一个目录只算一个工作区，再加入同目录的会话会替换旧的。
- **保存：** 存在 `~/Library/Application Support/AgentBell/tasks.json`，和会话列表分开，所以会话从「已关闭」里过期后任务仍然能恢复。文件读不出来时改名留在旁边，不会被覆盖。

## 5. 通知

内容由系统来画，我们只决定写什么、什么时候发（HIG：相关、看得懂、尊重注意力和隐私）。

| 事件 | 标题 | 副标题 | 正文 | 声音 |
|---|---|---|---|---|
| 等你确认 | ai-pet 等你确认 | 修复提醒按钮挤在一起 | 想改 PetSpeech.tsx，等你点头 | 系统默认 |
| 出错 | api-gateway 出错了 | 排查网关偶发 502 | 额度用完了 | 系统默认 |
| 做完（超过 30 秒） | robot 这一轮做完了 · 4 分钟 | 重写电机驱动 | 已把 PID 参数改成可配置，测试全部通过 | 无声 |

- 点通知：回到终端。通知上不加按钮。
- 你正看着那个会话时不发：最前面的是 Ghostty、iTerm2 或「终端」，焦点就在这个会话的终端上，且 30 秒内动过键盘或鼠标，系统通知和桌面气泡都不发，面板和菜单栏的灯照常亮。只在已经允许控制这个终端时检查，不为此申请权限；查不到就照常发。
- 同一个会话的通知归成一组（`threadIdentifier` 用会话 ID）。
- 你在终端里已经确认了，那条"等你确认"自动从通知中心撤回。
- **隐私：** 设置里有一项"通知里显示具体内容"，默认打开。关掉后只写"ai-pet 等你确认"，不写提问和回复。屏幕共享、开会时用得上。
- **申请通知权限的时机：** 连接成功之后，面板页脚上方出现提示条"还没允许通知，等你确认时不会提醒"，设置「通用」里连接状态下面也出现一行说明；用户读到用途、点"允许通知"，才弹系统的授权框。不在启动时、也不在连接的同时直接弹（HIG：在需要的时候、说清好处再申请）。

## 6. 设置窗口

`⌘,` 打开（HIG：设置用标准的入口和快捷键）。宽 480，顶部工具栏五个标签页：通用、桌面、通知、权限、关于，和系统自带应用的设置窗口一样；窗口标题跟着当前标签变，高度跟着内容变。每页都用分组表单（`.formStyle(.grouped)`），哪一页都不用滚动。

| 标签页 | 内容 |
|---|---|
| 通用 | Claude Code：状态行（灯，加"已连接 · 上次收到 2 分钟前"或"未连接"，右边"连接"或"断开"），`claude` 的位置（SF Mono，弱文字色，右边"更改…"）。终端：新会话在哪里打开，Ghostty、iTerm2、「终端」三选一，没装的标"未安装"，版本太旧的标"需更新"（Ghostty 要 1.4.0 或更新：AgentBell 的 Ghostty 脚本是按 1.4.0 写的）；选中的版本太旧时，下面一行写"Ghostty 1.3.1 太旧，需要 1.4.0 或更新"，给"更新"链接；选中的没装、或没装 Ghostty 时，下面一行给"下载"链接。新建会话前也检查版本，太旧就直接说明要更新，不去跑脚本。面板：排列方式和菜单栏图标开关。快捷键：打开面板、回到等你的会话，点一下录新的组合键。开机时启动 |
| 桌面 | 桌面图标开关、实时生效的大小滑块、常驻的五种状态说明。右键桌面图标可直接打开此页 |
| 通知 | 提醒方式：系统通知、桌面气泡。等你确认时、出错时、长回合做完时：三个开关，下面选多长算长回合（30 秒、1 分钟、3 分钟、5 分钟）。通知里显示具体内容：一个开关 |
| 权限 | 四行检查：通知、通知预览（"显示预览"设成"从不"时提示）、控制终端（每个装了的终端一行）、辅助功能（用来高亮跳到的分屏）。每行右边是"已允许"（次文字色），或"去打开"文字按钮 |
| 关于 | 图标、名字、版本、一句话介绍，"更新说明"弹出这一版的新变化（底部是支付宝赞赏码，不带收款人名字）；"更新"一行：检查更新；有新版本时"下载并安装"，下载中显示进度，下好后"重启完成更新"，失败时说原因并给"去下载页"；数据只在本机的说明，"数据文件夹"在访达中显示 |

- "断开"不弹确认框：断开随时可以重新连接，算可以撤销的操作（HIG：可撤销的常规操作不需要警告）。
- 改了马上生效，没有保存按钮。

## 7. 应用图标

macOS 标准的圆角方形。深石墨色的哑光底（`#1C1D1F` 到 `#141516` 的同色微渐变），中间偏左下一个浅灰的 `›_` 提示符，右上角一盏琥珀灯：实心、带一点点物理的灯罩厚度和柔和的高光，不发光晕。整体像一块真实的小仪器面板。

## 8. 无障碍

- 每一行的 VoiceOver 读法："ai-pet，修复提醒按钮挤在一起，等你确认，想改 PetSpeech.tsx，3 分钟"。灯本身不单独读。
- 菜单栏图标的读法跟着状态变："AgentBell，1 个会话等你"。
- 减弱动态效果：工作中的弧不转；面板直接出现，不做位移动画。
- 增强对比度：分隔线和行的底色加深，靠系统颜色自动处理。

## 9. 动效

- 面板出现：系统弹出层自带的动效，不自己加。
- 悬停和按下：只变底色，120ms。
- 行换位置（状态变了要重新排序）：200ms 的位置过渡；开了减弱动态效果就直接跳过去。
- 除了工作中的弧，没有一直在动的东西。

---

## 附：给 ChatGPT 生成设计图的提示词

用法：每张图都把「共同风格」整段放在最前面，再接那张图自己的描述。六张图用的是同一套数据，生成出来才能放在一起看。中文界面文字要求原样出现；模型写错字的话，单独指出哪几个字让它重画。

### 共同风格（每张都先粘这一段）

```
You are designing a native macOS 15 menu bar utility called AgentBell, for developers who run several Claude Code terminal sessions at once. It tells them which session is waiting for them, which finished, and takes them back to that terminal.

Visual direction: quiet, exact, considerate. Like a row of indicator lamps on a night-shift control desk: everything is calm grey, and only the lamp that matters is lit. Pure Apple Human Interface Guidelines look, as if Apple shipped it: system popover material, SF Pro for text, SF Mono for times and branch names, system label colors, hairline separators, 4pt spacing grid, generous but dense like a native macOS menu.

The product's own color exists only in small status lamps (8pt dots): amber #F5A524 means "waiting for you", green #2F9E62 means "finished", system red means "failed", a thin grey ring with a short rotating arc means "working", a thin faint ring means "idle". Everything else is neutral grey.

Strictly avoid: gradients on surfaces, glow, neon, colored shadows, glassmorphism beyond the native popover material, purple or violet, emoji, sparkles, badges like "NEW" or "AI", illustrations of robots or brains, uppercase tracked labels, bold heavy headings, exclamation marks, drop shadows other than the native macOS window shadow.

All interface text is Simplified Chinese and must be rendered exactly as quoted, crisp and legible, with correct characters. Render at 2x retina, pixel-precise, flat straight-on view (no perspective, no tilt), like a real macOS screenshot.
```

### 图 1：面板，浅色，有会话在等你

```
Image: a cropped real macOS screenshot, 1600x1200, light appearance. Top of the image is the macOS menu bar on a plain soft grey desktop wallpaper (no landscape, no gradient art). In the menu bar, among a few ordinary system icons, is the AgentBell icon: a 16pt rounded-square terminal outline with a small "›" prompt in its lower left and a small solid amber dot at its top right corner slightly overlapping the outline, followed by the number "1" in SF Mono.

Directly under that icon hangs a native macOS popover, 360pt wide, with the small arrow pointing at the icon, light popover material, native window shadow. Contents from top to bottom, left padding 12pt:

1. Header row, 13pt semibold: "1 个等你 · 1 个在工作". A hairline separator below.

2. Group label in 11pt semibold secondary grey: "ai-pet", and at the far right of the same line in SF Mono 11pt faint grey: "main".
   Row (two lines, this row is keyboard-selected so it has a subtle neutral grey rounded background, radius 6): left an amber solid dot; first line "修复提醒按钮挤在一起" in 13pt medium; right-aligned on the first line "等你" in dark amber #9A5B00 and "3 分" in SF Mono faint grey. Second line in 12pt secondary grey: "想改 PetSpeech.tsx，等你点头". At the far right of the second line a tiny keycap showing "↩".
   Row: left a thin grey ring with a short darker arc segment; first line "加使用统计页"; right "在工作" in secondary grey and "12 分"; second line "运行测试".

3. Group label "robot", right "feat/pid-tune".
   Row: green solid dot; "重写电机驱动"; right "做完" secondary grey and "刚刚"; second line "已把 PID 参数改成可配置，测试全部通过".

4. Group label "api-gateway", right "main".
   Row: red solid dot with a tiny white vertical stroke; "排查网关偶发 502"; right "出错了" in system red and "2 分"; second line "额度用完了".

5. Hairline separator, then a single 32pt row: "最近" and "3" in faint grey, and a small chevron pointing right at the far right.

6. Hairline separator, footer row 36pt in 12pt secondary grey: left "设置…" followed by a tiny keycap "⌘,"; right "退出" followed by a tiny keycap "⌘Q".

The popover feels quiet and dense like a native macOS menu; the only saturated color on the whole screen is the amber dot in the menu bar and in the first row, plus the small green and red dots.
```

### 图 2：同一个面板，深色

```
Image: exactly the same composition, data and layout as the previous light-mode screenshot, but in macOS dark appearance. Dark popover material, light text, the same small status dots (amber #F5A524, green #4CC38A, system red), the "等你" status word in light amber #F0B34A. Desktop wallpaper is a plain dark graphite. 1600x1200.
```

### 图 3：面板的空状态，还没连接

```
Image: a cropped macOS screenshot, 1200x1000, light appearance. The AgentBell menu bar icon (rounded-square terminal outline with "›" and a hollow ring lamp at its top right, no number) with a native popover under it, 360pt wide, about 300pt tall.

Inside, vertically centered with generous calm space: a single hollow grey ring lamp 32pt in diameter; below it 13pt medium text "连接 Claude Code 后，这里会列出你的会话"; below it, 12pt secondary grey, max two lines, centered: "会在 ~/.claude/settings.json 里加几条只读的钩子，改之前先备份" with the path in SF Mono. Below that a native macOS default push button "连接" using the system blue accent, and under it a small text link "会改动什么".

Footer row at the bottom with a hairline above: "设置…" with keycap "⌘,", and "退出" with keycap "⌘Q".
Nothing else on screen. No illustration, no mascot.
```

### 图 4：通知

```
Image: a cropped macOS screenshot, 1400x900, the top right corner of a plain soft grey desktop showing three stacked native macOS notification banners in light appearance, the standard Notification Center style with the app icon on the left and the app name "AgentBell" with the time.

The app icon: a macOS rounded-square icon, matte dark graphite tile, a light grey "›_" prompt in the lower left, and a single solid amber lamp at the top right with a tiny physical rim and a soft specular highlight, no glow.

Banner 1 (newest, top): title "ai-pet 等你确认", subtitle "修复提醒按钮挤在一起", body "想改 PetSpeech.tsx，等你点头", time "现在".
Banner 2: title "api-gateway 出错了", subtitle "排查网关偶发 502", body "额度用完了", time "2 分钟前".
Banner 3: title "robot 这一轮做完了 · 4 分钟", subtitle "重写电机驱动", body "已把 PID 参数改成可配置，测试全部通过", time "5 分钟前".

Exactly the native macOS banner design; no extra buttons on the banners.
```

### 图 5：设置窗口

```
Image: a macOS screenshot, 1400x1300, light appearance, a single native macOS settings window, 480pt wide, titled "AgentBell 设置", with traffic lights, centered on a plain soft grey desktop. It uses the native grouped Form style of macOS 15 System Settings (white rounded group boxes on a light grey window background, rows separated by hairlines, labels left, controls right).

Group "Claude Code":
  Row: a small green solid lamp dot, then "已连接", then secondary grey "上次收到 2 分钟前"; at right a native button "断开".
  Row: label "claude 的位置"; value in SF Mono faint grey "~/.local/bin/claude"; at right a native button "更改…".
Group "通知":
  Row "等你确认时" with a native switch on.
  Row "出错时" with a native switch on.
  Row "长回合做完时" with a native switch on, and a secondary grey caption under the label: "超过 30 秒的回合".
  Row "通知里显示具体内容" with a native switch on, caption "关掉后只写项目名，适合共享屏幕时".
Group "通用":
  Row "开机时启动" with a native switch off.
Group "权限":
  Row "通知" with secondary grey "已允许" at right.
  Row "通知预览" with a blue text link "去打开" at right, and caption "关着时横幅只显示「1 个通知」".
  Row "控制 Ghostty" with secondary grey "已允许" at right, caption "用来跳回会话所在的分屏".

Switches use the system accent color. No sidebar, no tabs, no icons in front of the rows, no hero banner.
```

### 图 6：图标规格表

```
Image: a clean design spec sheet, 1600x1000, plain very light grey background #F5F5F6, laid out like an Apple design resource page, small SF Pro labels in secondary grey under each item, no title banner.

Top row, left to right, the AgentBell menu bar icon shown large (each 128pt) and at actual size beside it, in four states, each drawn as a monochrome template glyph: a rounded-square terminal outline (1.5pt stroke, corner radius 3.5 on a 16pt grid) with a "›" prompt in the lower left and a small lamp at the top right corner slightly overlapping the outline:
  "空闲": lamp is a hollow ring.
  "在工作": lamp is solid black.
  "等你": lamp is solid amber #F5A524, followed by the digit "2" in SF Mono.
  "出错": lamp is solid red.
Show the same four once more on a dark menu bar strip below, adapted to white.

Bottom row: the status lamp set used inside the app, each at 8pt drawn large at 64pt with its label under it: amber solid "等你", grey thin ring with a short darker arc "在工作", grey dashed ring "后台在跑", green solid "做完", red solid with a small white vertical stroke "出错了", faint thin ring "空闲".

Right side: the macOS app icon at 512pt: matte dark graphite rounded-square tile, a light grey "›_" prompt slightly left of center and low, a single solid amber lamp at the top right with a tiny physical rim and soft specular highlight, no glow, no gradient other than a very subtle tonal shift within the graphite.
```
