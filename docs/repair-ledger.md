# Tidyreel 修复与验证台账

- 基线提交：`dc4a581`（保留低置信度手动选择与字幕跟随/忽略修复）
- 目标分支：`t3/tidyreel-repairs`
- 验证命令：`tool/check.sh`（通过 `/tmp/tr-check` 短路径 detached worktree 执行，规避 macOS 下 `libdart_smb2` 长路径 `install_name_tool` Mach-O headerpad 限制；实际 NAS / SMB 真机连接未实测）

## 15 项问题修复台账

### 一、执行与历史安全

| 编号 | 问题与根因 | 修复方案与涉及位置 | 回归测试与验证结果 |
|---|---|---|---|
| 1 | 刮削 `OpKind.write` 失败后执行 `retryFailed`/`resume`，仅凭目标路径 `exists()` 误判为“本批次已写入”，随后撤销时会删除用户原有文件 | `packages/tidyreel_core/lib/src/exec/executor.dart`：`resume` 恢复 `OpKind.write` 时发现已存在目标保守报告冲突，不依据内容一致推断文件所有权，避免撤销删除同内容用户文件 | `executor_test.dart`: `resume never claims identical pre-existing content or deletes it on undo`（通过） |
| 2 | 撤销 → 重新识别 → 再次执行后，`_batchOf()` 返回按时间/历史记录匹配到的旧批次，`TaskSummary.batch` 仍指向首次批次，导致二次撤销失败 | `packages/tidyreel_core/lib/src/task/default_task_manager.dart`：在 `_Task` 上记录 `priorBatches`（含历史旧/已撤销批次），`_batchOf(id, exclude: t.priorBatches, includeUndone: false)` 过滤旧批次并绑定本次新建批次 | `task_manager_test.dart`: `issue 2: undo -> retry -> run binds TaskSummary to the new batch and second undo works`（通过） |
| 3 | 导入或识别阶段取消任务后立即点击重试，旧异步流程未感知代数变化，回写旧的扫描结果、决策或计划覆盖新任务状态 | `packages/tidyreel_core/lib/src/task/default_task_manager.dart`：引入任务级 `pipelineGen` 代际计数，`_pipeline`/`_listAll` 各异步点检查 `stale()`，过期流程立刻中止不写回状态 | `task_manager_test.dart`: `issue 3: cancelled recognizer from old run cannot overwrite retried task review`（通过） |
| 4 | 目录重命名撤销时原目录已被占用，旧实现将目录 op 标记为 `skipped`，导致从 `activeFolders` 丢失后续文件路径映射且失去可重试撤销资格 | `packages/tidyreel_core/lib/src/exec/executor.dart`、`packages/tidyreel_core/lib/src/task/default_task_manager.dart`：被占用的目录撤销保留 `OpStatus.done` 并记录 `error`，后续文件还原按 `activeFolders` 正确映射当前目录；只要仍有未还原磁盘改动即保留部分失败/可重试撤销状态 | `executor_test.dart`: `blocked folder undo keeps folder done with error, preserves file mapping, and retries cleanly`；`task_manager_test.dart`: `issue 4: blocked folder undo keeps task non-undone and retryable until unblocked`（通过） |

### 二、显式用户决策与计划一致性

| 编号 | 问题与根因 | 修复方案与涉及位置 | 回归测试与验证结果 |
|---|---|---|---|
| 5 | `onlyConfident` 仅按 `warning` 过滤视频 op，却保留对应字幕和目录 op，导致视频未动而字幕被移动且任务标记 `done` | `packages/tidyreel_core/lib/src/task/default_task_manager.dart`：按主视频确认状态与目标路径依赖（`allowedWarning` / `postFolder`）一致性筛选；保留显式手动确认的低置信度视频及其依赖字幕，剔除未确认视频的附属字幕与孤立目录操作 | `task_manager_test.dart`: `issue 5: onlyConfident honors manually confirmed low-confidence video with its subtitle, and drops unconfirmed subtitles`（通过） |
| 6 | 并发调用 `updateDecision` 时重新规划耗时不同，后返回覆盖先返回导致“最后修改失效”；前端存在未落盘编辑时仍可触发执行 | `packages/tidyreel_core/lib/src/task/default_task_manager.dart`、`app/lib/features/review/review_page.dart`：后端引入 `editGen` 与 `pendingEdits` 计数，并发规划仅保留最新代际并在存在未落盘编辑时阻止 `run`；前端 `_pendingUpdates` 期间禁用执行按钮并拦截快捷键 | `task_manager_test.dart`: `issue 6: concurrent updateDecision enforces last-update-wins and blocks run while pending`；`review_page_test.dart`: `review regressions issue 6: pending updateDecision disables execute button and blocks shortcut`（通过） |
| 7 | 字幕/附属文件手动修改季/集号后仍强行跟随原视频（`S01E01`），且 UI 编辑字幕时误触发 `_shift` 连带重排视频 | `packages/tidyreel_core/lib/src/plan/planner.dart`、`app/lib/features/review/review_page.dart`：规划器优先使用附属文件自身的显式 `FileOverride` 季/集/年份解析结果，仅在未显式指定时回退跟随视频；UI 仅当 `row.file.role == FileRole.video` 时触发 `_shift` | `planner_test.dart`: `issue 7: manually edited subtitle uses its selected season/episode`；`review_page_test.dart`: `review regressions issue 7: editing a subtitle updates only that subtitle and does not shift videos`（通过） |
| 8 | 忽略主视频后显式勾选其有效字幕/附属文件，规划器只遍历未忽略视频，导致任何有效字幕操作都无法生成 | `packages/tidyreel_core/lib/src/plan/planner.dart`、`app/lib/features/review/review_panes.dart`：为被忽略视频下带有显式选择或有效覆盖的 `_Companion` 独立规划重命名与目录归属，保留剧名上下文且不误选原视频；UI `_VideoBlock` 在有选中附属项时默认/自动展开并标示警告 `Tag` | `planner_test.dart`: `issue 8: explicitly edited/selected subtitle still plans when its video is ignored`；`review_page_test.dart`: `review regressions issue 8: ignoring video expands companions and companion warning tag is shown`（通过） |
| 9 | 手动编辑 `FileOverride(episode: 0)` 绕过自动解析校验，直接生成无警告的 `S01E00` | `packages/tidyreel_core/lib/src/plan/planner.dart`、`app/lib/features/review/review_panes.dart`：对剧集最终解析结果统一校验 `season >= 0 && episode >= 1`（合法第 0 季特别篇允许保留），无效手动项带警告阻止默认选中；UI `_EditRowSheetState` 实时校验输入，显示 `edit-validation-error` 并禁用保存按钮 | `planner_test.dart`: `issue 9: manual invalid episode/season is rejected while valid specials remain selected`；`review_page_test.dart`: `review regressions issue 9: manual edit validates season/episode and accepts valid specials`（通过） |

### 三、交互体验与流程连贯性

| 编号 | 问题与根因 | 修复方案与涉及位置 | 回归测试与验证结果 |
|---|---|---|---|
| 10 | 同部剧集同一集存在重复下载时产生默认合并冲突，执行按钮被禁用且 `_execute` 直接返回，导致无法打开 `showMergeDialog` 选择「分开保留」解决冲突 | `app/lib/features/review/review_page.dart`：当预览存在可由用户决策的合并项（`merges.isNotEmpty`）时允许点击执行打开 `showMergeDialog`；用户在弹窗选择「分开保留」后重新读取最新计划复查冲突再决定放行或提示 | `planner_test.dart`: `issue 10 backend: duplicate downloads conflict via merge and separate clears conflict`；`review_page_test.dart`: `review regressions issue 10: merge conflict opens dialog, warns if kept merged, and executes when separated`（通过） |
| 11 | `shiftFrom` 顺延剧集时直接 `+1` 递增，把缺失的集号（如 12、14 缺 13）压缩为连续编号，还会误计特别篇并拆散同集多版本 | `app/lib/features/review/review_logic.dart`：`_isMainVideo` 排除第 0 季与特别篇/花絮；`shiftFrom` 按原集号差值步进保留缺集间隔并在跨季边界正确进位，同时保持同一集多版本文件同步更新 | `review_logic_test.dart`: `shiftFrom preserves missing-episode gaps and rolls gaps across seasons`、`shiftFrom keeps duplicate representations together and skips parsed specials`（通过） |
| 12 | `setMode` 在构建计划前就写入新模式，若切换到 `moveToLibrary` 但缺少 `libraryRoot` 抛出异常后，状态残留在新模式与旧原地计划 | `packages/tidyreel_core/lib/src/task/default_task_manager.dart`：`setMode` 先验证并生成新模式计划成功后再提交模式、选项与预览；任何失败均回滚并维持原模式与计划，界面展示错误提示 | `task_manager_test.dart`: `issue 12: failed setMode restores original mode and plan atomically`（通过） |
| 13 | 修改命名规则或设置后重新进入 `awaitingReview` 任务仍返回缓存旧计划且以此执行；或触发全量重扫 | `packages/tidyreel_core/lib/src/model/naming.dart`、`model/plan.dart`、`tidyreel_core.dart`、`default_task_manager.dart`、`review_page.dart`：为 `NameRewrite`/`NamingOptions`/`NamingProfile`/`PlanOptions` 实现值语义相等；`review()`/`run()` 比对当前配置是否变化，仅对未完成/待确认任务基于已有扫描结果增量重建计划（不重扫、不重算已完成任务）；`ReviewPage` 监听命名/设置/连接 provider 自动刷新预览 | `task_manager_test.dart`: `issue 13: reopening awaiting-review task reflects updated naming profile without rescan, and finished tasks stay unchanged`；`review_page_test.dart`: `review regressions issue 13: changing namingProfileProvider reloads awaiting ReviewPage preview`（通过） |
| 14 | 已取消但已实际产生执行批次的任务后端支持撤销，但 `TaskCard` 与 `TaskDetailPage` 仅对 `done`/`partiallyFailed` 展示撤销按钮 | `packages/tidyreel_core/lib/src/model/task.dart`、`app/lib/features/tasks/tasks_page.dart`、`task_detail_page.dart`：新增 `canUndo(TaskSummary)` 统一前后端可撤销判断（含有效 `batch` 的 `cancelled` 任务，并保留部分撤销提示展示） | `tasks_page_test.dart`: `issue 14: cancelled task with executed batch exposes undo in card and detail`（通过） |
| 15 | `UnassignedPane` 始终文案承诺「整理时原样保留」，但 `deleteJunk=true` 时实际计划已选中删除未分配垃圾文件 | `app/lib/features/review/review_panes.dart`、`app/lib/features/review/review_page.dart`：新增 `plannedUnassignedDeletes`，根据实际 `RenamePlan` 在侧栏副标题与 `UnassignedPane` 顶部摘要区分展示保留与将删除数量，并为待删文件标注 `将永久删除` 标签（保留原有二次确认） | `review_page_test.dart`: `review regressions issue 15: UnassignedPane and sidebar distinguish kept vs deleted junk files`（通过） |

## 全量验证记录

在 `/tmp/tr-check` 短路径同步全部工作区改动后执行 `/tmp/tr-check/tool/check.sh`（环境变量 `PATH=/opt/homebrew/opt/git/bin:$PATH`）：

- 版本一致性校验：`app/pubspec.yaml` 与 `app/lib/version.dart` 一致
- `packages/tidyreel_core`：
  - `dart format --set-exit-if-changed lib test`：131 + 69 个文件格式无变更
  - `dart analyze`：`No issues found!`
  - `dart test`：`+417 ~5` 全部通过（5 个跳过的测试为原有环境条件测试）
- `app`：
  - `dart format --set-exit-if-changed lib test`：62 个文件格式无变更
  - `flutter analyze`：`No issues found!`
  - `flutter test`：`+114 ~3` 全部通过（3 个跳过的测试为原有 `smb_live_test.dart` / 条件测试）

## 父级复核补充

- 相同字节不代表本批次所有权；恢复时已存在但未记为完成的写入保留文件并报告冲突。崩溃发生在文件写入与历史落盘之间时，此类刮削文件需用户核对，不能自动认领或撤销删除。
- 执行取得任务锁之后拒绝新决定与模式编辑，避免执行准备期间插入修改。
- 设置变化触发 `ReviewPage` 预览刷新期间，禁用执行入口直到新预览返回。
