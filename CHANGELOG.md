# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。由 `tool/release.sh` 根据提交说明生成，发布前可以手动润色。

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
