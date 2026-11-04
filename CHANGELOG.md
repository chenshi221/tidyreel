# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。由 `tool/release.sh` 根据提交说明生成，发布前可以手动润色。

## [0.4.0] - 2026-11-04

### 新功能

- **地图**：新增仓库大小地图；每一项都单独显示，放不下时可拖动和缩放，支持多选，刷新会重新统计
- **地图**：已按 `名称 (年份)` + `SxxEyy` 整理好的内容自动算作已整理，也可以右键手动标记
- **来源**：连接路径成为访问边界，不能再往上；新增回到主页和上一级按钮
- **命名规则**：季文件夹预设、变量按钮和正则替换规则
- **整理**：选中的作品决定按电影还是剧集整理；可按识别结果改名文件夹
- **任务**：任务页重做，默认显示全部

### 改进

- **界面**：全新单色设计和应用图标，页面分区更清楚；设置和任务详情铺满宽度
- **确认页**：简介可展开，季和文件夹标签等高；待手动识别清空后自动跳到可整理

### 修复

- **搜索**：重新搜索不再被当前匹配的年份和类型筛掉正确结果（如搜“翠鸟”找不到《翠鸟谋杀案》）
- **搜索**：可以用别名找到剧集，手动匹配后可以选择季
- **地图**：修复项目多时小块几乎看不见
- **界面**：修复收起侧栏时按钮被红绿灯遮挡、“最近整理”一行溢出
- 修复代码审查发现的核心引擎和应用问题

## [0.3.0] - 2026-11-02

包含未单独发布的 0.2.0 的全部内容（见下方）。

### 新功能

- **识别**：罗马音片名（如 Futsutsuka na Akujo dewa Gozaimasu ga）TMDB 搜不到时，经 AniList 查日文 / 英文名再匹配
- **识别**：内容类型 混合 / 动漫 / 电视剧 / 电影，可在设置或多选栏切换
- **识别**：只含一部作品、且以作品命名的导入文件夹，直接改名为作品文件夹，里层变成 Season 01
- **整理**：TMDB 片名只差标点时保留原名；超出 TMDB 集数的集照常命名并默认勾选
- **整理**：外挂音轨（.mka / .ac3 / .dts 等）跟随视频一起改名
- **确认页**：字幕、音轨折叠在对应集下；新增「未归类」页，列出没归进作品的文件和原因
- **来源**：已选列表可查看、移出、跳转；搜索支持模糊匹配

### 修复

- 片名中含 Menu、PV 等词（如「卫宫家今天的饭 Today's Menu…」）不再被当成特典
- 确认页字幕按完整文件名或集数配对，不再全部挂到第一集

### 性能

- 目录列表在浏览、预览、导入之间共享缓存，切回来源不再重新加载
- 预览和导入并发遍历文件夹；冲突检查按文件夹合并请求
- 同一 Alist 服务器的连接共用登录；TMDB 结果本地缓存 7 天
- 撤销按文件夹批量改名 / 移动，其余并行

### 其他

- CI 检查前拉取 core 依赖（之前 PR 检查和发版构建会因此失败）

## [0.2.0] - 2026-11-01

### 新功能

- **app**：build all five UI pages (sources, tasks, review, naming, settings)
- **parser**：air dates, episode ranges and "1 of 6" numbering
- **planner**：reuse a lone quality folder as Season 01
- **storage**：batch rename and a retryable busy error
- **task**：retry failed ops and delete task records
- **sources**：scan preview before submit and right-click menus
- **review**：pick episodes from TMDB and shift the ones after
- **tasks**：detail page, delete and retry actions
- **settings**：engine, TMDB, appearance and data settings

### 修复

- **webdav**：follow redirects, address collections with a trailing slash
- **data**：keep secrets in secrets.json instead of the keychain

### 性能

- **exec**：batch file ops per folder and run four at a time

### 界面

- fade-in motion, gradient progress and context menus

### 其他

- 提交、PR 和发版规范（CONTRIBUTING.md）、commit-msg 检查、`tool/release.sh` 发版脚本
- 每个 PR 自动跑检查；发版时校验标签和 pubspec 版本一致

这是首个带版本号的发布，更早的开发记录见 git 历史。
