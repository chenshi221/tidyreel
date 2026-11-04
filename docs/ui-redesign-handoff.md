# UI 重设计：交接与后续计划

分支：`claude/great-lamport-8yexcb`。目标：借鉴 Kanso 的**设计语言**（灰阶纸感、大字号细体、几乎没有容器、文字优先），
加一个「仓库地图」（按大小排布的有机色块，未整理的部分用等高线表示）。**不照搬它的页面结构、名称和文案。**

## 已完成（已提交）

| 提交 | 内容 | 状态 |
|---|---|---|
| `ui: quieter monochrome design language` | `app/lib/ui/{tokens,theme,widgets}.dart`：米白/炭黑色板、5 档 `tones` + `contour`、墨色描边控件、方形复选框；强调色只留给「待确认」和主按钮；新控件 `Spinner` / `BigNumber` / `LinkText`；设置里新增「墨」强调色 | 测试全绿 |
| `feat(map): repository size map in the file browser` | `app/lib/features/map/`：`size_scanner.dart`（只读递归统计）、`map_providers.dart`、`repo_map_view.dart`；文件浏览器加「列表 \| 地图」开关 | 测试全绿 |
| `feat(map): voronoi treemap pebbles with smooth corners` | `organic_layout.dart` 改成加权 power diagram（Voronoi treemap）+ Chaikin 磨圆；`organic_map.dart` 拉满明暗、缝隙轻微变化、等高线绕开标签 | 测试全绿；截图效果已获认可 |
| `ui(sources): text column with live map, text-only sidebar (wip)` | 来源页改成「左栏文字 + 右侧常驻地图」；侧边栏展开时只显示文字；`PageScaffold` 改成 30pt 细体标题、48px 页边距；`BigNumber` 的说明文字可以换行 | **测试未全绿**，见下文 |
| 本次提交 | `organic_map.dart` 的布局缓存改成按内容（id + 大小）判断 | **未验证** |

## 已知问题（接手后先处理）

1. **地图性能（最高优先级）**：之前布局缓存用 `identical(widget.blocks, ...)` 判断，而 `mapBlocksFor` 每次都返回新列表，结果每次重绘（包括鼠标悬停）都把 Voronoi 迭代 120 轮重算一遍。
   导致 `test/features/map/repo_map_view_test.dart` 从约 2 秒变成约 80 秒，`test/screenshots_test.dart` 卡死。
   本次提交已经把缓存键改成内容（`id + bytes`），**但还没跑测试验证**。如果还慢，可以再加：统计进行中最多每 1 秒重新布局一次，统计结束后再精确算一次。
2. **`test/features/connection_dialog_test.dart` 有 1 个失败**，还没定位。可疑点：来源页连接行改成了 `Hoverable`（key `conn <id>` 保留，点击仍然打开浏览器），可能是测试依赖的文本或布局变了。
3. **`repo_map_view_test.dart` 里的断言要更新**：统计完成后不再显示「统计完成」，改成显示「N 个文件 · 未整理 X」（见 `RepoMapSummary`）。
4. 截图测试 `map screens` 依赖 `demo-alist` 的 `libraryRoot == /影视库` 和 `fake_library.dart`；来源页现在会自动统计第一个连接的媒体库根目录。

## 后续计划

- **第 2 步收尾**：修好上面 1～3，跑通 `tool/check.sh`，出截图（来源页浅色、深色，以及窄窗口）。
- **第 2 步 b：任务页文字化**（`app/lib/features/tasks/tasks_page.dart`）：
  - 顶部大数字显示「N 个待确认」（用 `BigNumber`）；
  - 任务从卡片改成文字条目：标题 16pt，下面一行灰字写来源路径和任务 ID；
  - 五段进度条改成一行文字「◌ 正在识别 312/800」（用 `Spinner`）；
  - 按钮改成一个描边按钮加一个文字按钮。
- **第 3 步**：命名规则、设置、任务详情、识别结果三栏统一过一遍（去掉 `Panel` 卡片、统一页边距和字号），只换风格，不改布局。
- **以后再做**：统计结果存进 drift（重启后秒出）；地图数据变化时的形状过渡动画；大网盘统计限速或设置开关。

## 环境与命令

- 云端容器里的 Flutter 3.47.4 装在 `/opt/flutter-sdk/flutter/bin`，需要先 `export PATH=/opt/flutter-sdk/flutter/bin:$PATH`。
- 截图：
  `SHOTS_DIR=<输出目录> FONTS_DIR=/opt/fonts FLUTTER_ROOT=/opt/flutter-sdk/flutter flutter test test/screenshots_test.dart`
  （`/opt/fonts` 里放的是复制成 Noto 文件名的文泉驿字体，没有细体，个别字形缺失；真机上用苹方/SF 会更细）。
- 只跑相关的测试；全量 `tool/check.sh` 留到提交前再跑。跑测试时带 `--timeout 60s`，并在外面套一层 `timeout`，防止卡死。
