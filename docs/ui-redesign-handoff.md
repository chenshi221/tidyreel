# UI 重设计：交接与后续计划

分支：`claude/great-lamport-8yexcb`。目标：借鉴 Kanso 的**设计语言**（灰阶纸感、大字号细体、几乎没有容器、文字优先），
加一个「仓库地图」（按大小排布的有机色块，未整理的部分用等高线表示）。**不照搬它的页面结构、名称和文案。**

## 已完成（已提交）

| 提交 | 内容 | 状态 |
|---|---|---|
| `ui: quieter monochrome design language` | `app/lib/ui/{tokens,theme,widgets}.dart`：米白/炭黑色板、5 档 `tones` + `contour`、墨色描边控件、方形复选框；强调色只留给「待确认」和主按钮；新控件 `Spinner` / `BigNumber` / `LinkText`；设置里新增「墨」强调色 | 测试全绿 |
| `feat(map): repository size map in the file browser` | `app/lib/features/map/`：`size_scanner.dart`（只读递归统计）、`map_providers.dart`、`repo_map_view.dart`；文件浏览器加「列表 \| 地图」开关 | 测试全绿 |
| `feat(map): voronoi treemap pebbles with smooth corners` | `organic_layout.dart` 改成加权 power diagram（Voronoi treemap）+ Chaikin 磨圆；`organic_map.dart` 拉满明暗、缝隙轻微变化、等高线绕开标签 | 测试全绿；截图效果已获认可 |
| `ui(sources): text column with live map, text-only sidebar (wip)` | 来源页改成「左栏文字 + 右侧常驻地图」；侧边栏展开时只显示文字；`PageScaffold` 改成 30pt 细体标题、48px 页边距；`BigNumber` 的说明文字可以换行 | 已修复，测试全绿 |
| 本次提交 | `organic_map.dart` 的布局缓存改成按内容（id + 大小）判断 | 已验证 |

## 进度更新

- 已修：地图布局缓存（地图测试从约 80 秒降到约 1 秒，截图测试不再卡死）、统计开始时在构建阶段发通知（`connection_dialog_test` 失败的原因）、地图测试断言。
- 已修：媒体库路径不存在时，错误改成中文提示，地图不再一直转圈。
- 已做：任务页文字化（大数字、文字条目、一行进度文字）。
- 已做：`Panel` 默认不画框，只有需要边界的滚动列表传 `framed: true`；所有页面靠左对齐，边距统一。

## 后续计划

- 识别结果页的作品卡和文件行有自己的容器，这轮没动，还需要看要不要继续简化。
- 以后再做：统计结果存进 drift（重启后秒出）；地图数据变化时的形状过渡动画；大网盘统计限速或设置开关。
- 合并 PR #3（搜索别名和选集弹窗）后同步 `main`，在选集弹窗的 `Panel` 上保留 `framed: true`。

## 环境与命令

- macOS 上没有 Noto 字体时，可以把系统的 `Arial Unicode.ttf` 复制成 `NotoSansSC-{Regular,Medium,Bold}.otf` 和 `NotoSerifSC-{Regular,SemiBold}.otf`，放进 `FONTS_DIR` 再截图，个别字形会显示成黑块。
- 云端容器里的 Flutter 3.47.4 装在 `/opt/flutter-sdk/flutter/bin`，需要先 `export PATH=/opt/flutter-sdk/flutter/bin:$PATH`。
- 截图：
  `SHOTS_DIR=<输出目录> FONTS_DIR=/opt/fonts FLUTTER_ROOT=/opt/flutter-sdk/flutter flutter test test/screenshots_test.dart`
  （`/opt/fonts` 里放的是复制成 Noto 文件名的文泉驿字体，没有细体，个别字形缺失；真机上用苹方/SF 会更细）。
- 只跑相关的测试；全量 `tool/check.sh` 留到提交前再跑。跑测试时带 `--timeout 60s`，并在外面套一层 `timeout`，防止卡死。
