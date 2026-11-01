# 参与开发

## 开始之前

```sh
tool/install_hooks.sh   # 启用 commit-msg 检查（每个 clone 执行一次）
tool/check.sh           # 格式、静态检查、两个包的全部测试；提交前必须通过
```

## 提交规范

采用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/v1.0.0/)：

```
类型(范围): 说明

正文（可选）：为什么这样改、有什么取舍。每行不超过 72 字符。

BREAKING CHANGE: 不兼容改动的说明（可选）
```

- **说明**用英文、祈使句、小写开头、结尾不加句号，整行不超过 72 个字符。
- 一个提交只做一件事；格式化、重命名这类改动单独提交。
- `tool/lint_commit.sh` 负责检查，本地 `commit-msg` hook 和 PR 标题检查都用它。

| 类型 | 用途 | 版本影响 |
|---|---|---|
| `feat` | 新功能 | 次版本号 +1 |
| `fix` | 修 bug | 修订号 +1 |
| `perf` | 性能优化 | 修订号 +1 |
| `ui` | 只改界面样式和交互，不改行为 | 修订号 +1 |
| `refactor` | 重构，行为不变 | — |
| `test` | 只改测试 | — |
| `docs` | 只改文档 | — |
| `build` | 依赖、构建脚本 | — |
| `ci` | GitHub Actions | — |
| `chore` | 其他杂项；`chore(release)` 留给发版 | — |
| `revert` | 撤回某个提交 | 看被撤回的内容 |

类型后加 `!`（如 `feat(storage)!: …`），或者正文写 `BREAKING CHANGE:`，表示不兼容改动，主版本号 +1（1.0 之前改为次版本号 +1）。

**范围**用模块名，可以不写：

- 核心库 `packages/tidyreel_core`：`parser` `planner` `exec` `storage` `task` `tmdb`
- 应用 `app`：`review` `sources` `tasks` `naming` `settings` `ui` `data`
- 其他：`ci` `release` `deps`

示例：

```
feat(review): pick the episode from the TMDB list when fixing a row
fix(storage): map Windows "Access is denied" to a retryable busy error
perf(exec): batch renames per folder with Alist batch_rename
ui(tasks): backdrop tint and gradient progress on task cards
```

## 分支与 PR

- 从 `main` 拉分支，命名为 `类型/简短描述`，例如 `feat/scan-preview`、`fix/webdav-redirect`。
- **PR 标题**遵循上面的提交规范（CI 会检查）。合并时用 **Squash and merge**，PR 标题就是写进 `main` 的那条提交说明。
- **PR 正文**用中文，按模板填写：概要、改动、怎么测的、截图、风险与回滚。
- CI（`.github/workflows/checks.yml`）跑 `tool/check.sh`，通过后才能合并。
- 会改动或删除用户文件的功能，必须有确认步骤和历史记录（PLAN §4.3），在 PR 里写清楚。
- 不要提交任何密钥：TMDB token 只放在被 gitignore 的 `app/tmdb.local.json` 和仓库的 `TMDB_TOKEN` secret 里。

## 版本与发布

- 版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。唯一来源是 `app/pubspec.yaml` 的 `version: X.Y.Z+构建号`；`app/lib/version.dart` 由发版脚本同步写入，`tool/check.sh` 会检查两者一致。
- 1.0 之前：新功能升次版本号（0.2.0 → 0.3.0），修复升修订号（0.2.0 → 0.2.1）。
- 发版：

  ```sh
  tool/release.sh 0.3.0      # 改版本号、生成 CHANGELOG、提交 chore(release)、打本地标签
  # 检查并润色 CHANGELOG.md（可以 git commit --amend；之后要重打标签 git tag -fa v0.3.0）
  git push && git push origin v0.3.0   # 推送标签后 Release 工作流构建并发布
  ```

- Release 工作流会检查标签和 pubspec 版本是否一致，并用 `CHANGELOG.md` 里对应版本的那一节作为发布说明。
