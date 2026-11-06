# 理片 Tidyreel — 开发方案 v0.1

> 一个把网盘里乱七八糟的影视资源，整理成 VidHub 能正确刮削的命名和目录结构的桌面软件。
> Flutter 编写，第一版支持 macOS，顺带支持 Windows；界面按宽屏设计，平板放到后续版本。

---

## 0. 已确定的决策

| 项目 | 决定 |
|---|---|
| 名称 | 理片 Tidyreel（包名 `tidyreel`，Bundle ID `app.tidyreel`） |
| 平台 | v1：macOS（主力）+ Windows；平板以后再做，布局现在就按宽屏和触控尺寸设计 |
| 引擎 | 用 Dart 重写，参考 mnamer（MIT 协议，在 `LICENSES/` 保留原版权声明）。不依赖 Python |
| 数据来源 | 支持多个连接：**Alist/OpenList API**（主力）、**WebDAV**、**本地文件夹** |
| 识别 | 只用规则识别，不接 AI；识别失败时在 TMDB 里手动搜索 |
| 元数据 | TMDB，用户自己填 API key，支持自定义 API 代理地址（Base URL） |
| 命名 | 用「命名选项」可视化配置（每个选项都实时预览），底层编译成模板；高级用户可以直接改模板。电影和剧集分开设置 |
| 任务模型 | 扫描和识别作为**后台任务**运行，可以同时有多个任务；任务中心统一查看进度、确认、执行和取消 |
| 整理模式 | 原地改名，或移动到媒体库目录，每次任务选一种 |
| 附加功能 | 字幕跟随改名、清理垃圾文件（确认后才删）、特别篇归入 Season 00、花絮放进 Extras |
| 撤销 | 每次执行都保存历史，可以撤销整批或单个文件 |
| UI | Material 3，桌面紧凑布局，支持深色模式 |
| 发布 | 第一版自用，不做签名公证和自动更新；代码按开源标准写 |

---

## 1. 用户流程（功能逻辑参考 Filmix，界面自己设计）

```
① 来源 ──▶ ② 浏览并多选 ──▶ ③ 提交成任务 ──▶ ④ 后台导入和识别 ──▶ ⑤ 待确认 ──▶ ⑥ 执行 ──▶ ⑦ 已完成，可撤销
                                         └──────────── 任务中心统一管理 ────────────┘
```

1. **来源**：保存多个连接（Alist / WebDAV / 本地），显示连接状态（已连接、认证失败、离线）。每个连接可以设置一个「媒体库根目录」，移动模式下整理好的文件放到这里。另外支持**收藏文件夹**，常用的下载目录可以一键直达。
2. **浏览**：
   - 面包屑导航，在当前文件夹内搜索，按名称、时间或大小排序。
   - 筛选「**只看未整理的**」：历史库里已经整理过的路径，以及文件名已经符合当前命名规则的，都会被隐藏。
   - 进入多选模式后可以全选，文件夹和单个文件都能选。
3. **提交**：选中的路径打包成一个**任务**，任务 ID 用短格式，比如 `T12-ec72df`。提交后马上回到浏览页，可以继续选下一批，任务在后台跑。
4. **导入和识别**（后台进行）：
   - 先递归列出所有文件，界面显示实时计数（已导入 N 个文件）。
   - 按类型分类：视频、字幕、附属文件、垃圾文件。
   - **锚点识别**：先用文件夹名，加上文件名里出现最多的片名，确定「这是哪部片」，然后逐个文件解析季集。比每个文件各自去搜 TMDB 更准，请求也少得多。
5. **待确认**：识别完成后，任务停在「待确认」，等用户确认后才执行。任务卡片上显示「识别完成，请确认」，有两个入口：
   - **去确认**：进入识别结果页（见 §5）。
   - **立即执行**：信任识别结果时一键执行，只执行高置信、没有冲突的项。
6. **执行**：分两个阶段，**文件重命名 → 文件夹重命名或移动**，任务卡片上能看到每个阶段的进度。整理模式（原地或移动）在提交任务时选好，确认时还能改。
7. **已完成**：任务进入「已完成」列表，可以撤销整批或单个文件。

**任务状态机**：`导入中 → 识别中 → 待确认 → 执行中(文件) → 执行中(文件夹) → 已完成 / 部分失败 / 已取消 / 已撤销`。任何一个阶段都可以取消；执行中途取消时，已经完成的操作照样记入历史，可以撤销。任务和状态都保存在 drift 数据库里，重启软件后不会丢。

---

## 2. 季集策略

每个**剧集分组**可以单独选择一种策略，默认用「识别到的季集」。

| 策略 | 适用 | 规则（N 是绝对集号，c[s] 是 TMDB 第 s 季的集数，不算 Season 0） |
|---|---|---|
| **默认：识别到的季集** | 权力的游戏 S06E05 | 直接用文件名或文件夹名解析出来的季号和集号 |
| **顺序拆多季** | 龙珠Z，1 季共 291 集 | 按 TMDB 每季的集数累加：先找到满足 Σc[1..s-1] < N ≤ Σc[1..s] 的季 s，新集号 = N − Σc[1..s-1]，每季都从 E01 开始 |
| **跳序拆多季** | 海贼王，1 季共 1119 集 | 用同样的方法找出季 s，但**集号保持 N 不变**，结果是 S21E1080 这样，只改季号 |
| **合并成一季** | 名侦探柯南，原本有多季 | 新集号 = Σc[1..s-1] + e，全部归入 S01。这里 c 用分组里**源文件的季结构**：优先按 TMDB 每季集数，没有时按本地每季的最大集号 |

补充：
- 每个分组都可以设置**集数偏移**（±k），用来处理字幕组从 0 开始编号、或者整体错位的情况。偏移在策略计算**之前**生效。
- 可以选用 TMDB 的 **Episode Groups**（剧集分组）代替默认的季划分。很多动漫在 TMDB 上有「按绝对顺序」「按篇章」这类分组，作为 c[s] 的来源更准确。这一项在 v1 做成可选功能。
- 拆分时如果 N 超过了 TMDB 上的总集数（比如还在连载、TMDB 没更新），把多出来的集归到最后一季继续往下数，并在界面上标黄提醒。
- 策略都是**纯函数**，形式为 `(List<EpisodeRef>, SeasonLayout) → List<EpisodeRef>`，必须有完整的单元测试。

---

## 3. 命名模板

### 3.1 语法（自己实现一个简单的，不引入模板库）

- 变量：`{title}` `{original_title}` `{year}` `{season}` `{episode}` `{episode_title}` `{tmdbid}` `{resolution}` `{version}` `{ext}` `{lang}`
- 格式化：`{season:02}` 表示补零到两位
- 可选段：`[ - {episode_title}]`，段里有任何一个变量为空时，整段都去掉
- 路径分隔统一用 `/`，由各个存储后端自己转换
- 渲染完要清理非法字符：`\ / : * ? " < > |` 替换成全角字符或删掉，并去掉末尾的点和空格（Windows 和网盘都有这个限制）

### 3.2 命名选项（设置页可视化配置，编译成 §3.1 的模板）

电影和剧集**分开**设置。页面顶部固定显示一个示例，比如把
`老友记.1994.S02E03.2160p.Dolby.BluRay.x265.mp4` 转换成 `老友记.Friends.1994.S02E03.mp4`，任何选项一改，示例马上刷新。

| 选项 | 可选值（**粗体**是默认） | 电影 | 剧集 |
|---|---|---|---|
| 目标播放器 | **VidHub** / Infuse / Plex / Emby·Jellyfin（切换后整套恢复成该播放器的推荐默认值） | ✓ | ✓ |
| 标题语言 | **中文优先** / 英文（原名）优先；勾选「同时用两种语言」时两种都写，默认勾选 | ✓ | ✓ |
| 年份 | 开关（**开**）；格式 **`1999`** / `(1999)` | ✓ | ✓ |
| 剧集年份取哪个 | **首季年份** / 当季首播年份 | | ✓ |
| 季集格式 | **`S01E02`** / `s01e02` / `s1e2` / `1x02` / `s01.e02` | | ✓ |
| 分集标题 | 开关（关） | | ✓ |
| 附加信息 | 开关（关）；开启后保留分辨率、HDR、音轨这类信息，比如 `2160p.DV` | ✓ | ✓ |
| 分隔符 | **`.`** / `_` / 空格 / `-` | ✓ | ✓ |
| 发布组 | 开关（关）；开启后在末尾加 `-GRP` | ✓ | ✓ |
| TMDB ID 标签 | 开关（关），格式 `{tmdb-12345}` | ✓ | ✓ |
| 字段顺序 | 用拖动排序决定 标题、年份、季集、附加信息 的先后 | ✓ | ✓ |
| 文件夹命名 | 单独设置，默认 `{title} ({year})`，季文件夹 `Season {season:02}` | ✓ | ✓ |
| 高级 | 直接编辑模板，选项面板变成只读 | ✓ | ✓ |

**VidHub 默认结果**：
- 电影：`电影/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv`
- 剧集：`剧集/老友记 (1994)/Season 02/老友记.Friends.1994.S02E03.mkv`

> 以上默认值参考了 Filmix 给 VidHub 的推荐格式（点分隔、中英双语、年份不加括号）。M2 结束时要在真实的 VidHub 里实测确认。

- 特别篇：`Season 00/{title} S00E{episode:02}.{ext}`
- 花絮：`{剧集或电影目录}/Extras/{原文件名}`
- 字幕：`{视频新名去掉扩展名}[.{lang}].{sub_ext}`。语言标签沿用原文件里的，比如 `.zh-CN`、`.chs`、`.sc`、`.简体`，统一映射成 `zh-Hans`、`zh-Hant`、`en` 这样的标准写法
- 原地模式：模板里第一段（`电影/` 或 `剧集/`）去掉，从分组所在的目录开始放

> ⚠️ 待验证：VidHub 没有公开的命名文档，以上沿用 Infuse/Plex 的惯例。M2 结束时要用真实的 VidHub 实测三件事：多版本后缀写法、Extras 文件夹名、文件夹带 `{tmdb-xxx}` 时能否识别。根据结果再调整默认预设。

---

## 4. 架构

```
tidyreel/
├─ packages/
│  └─ tidyreel_core/          # 纯 Dart，不依赖 Flutter，用 `dart test` 跑测试
│     ├─ lib/src/model/       # 数据模型（普通不可变类）
│     ├─ lib/src/parser/      # 文件名解析
│     ├─ lib/src/tmdb/        # TMDB 客户端和匹配
│     ├─ lib/src/storage/     # 存储后端：Alist / WebDAV / Local
│     ├─ lib/src/plan/        # 分组、策略、模板、字幕和附属文件 → 生成执行计划 RenamePlan
│     ├─ lib/src/exec/        # 执行器、撤销
│     ├─ lib/src/task/        # 任务状态机和 TaskManager
│     └─ test/fixtures/       # 文件名测试语料，Agent A 负责维护
└─ app/                       # Flutter 应用
   ├─ lib/features/connections/
   ├─ lib/features/browser/
   ├─ lib/features/review/
   ├─ lib/features/history/
   ├─ lib/features/settings/
   └─ lib/data/               # drift 数据库、安全存储、Riverpod providers
```

### 4.1 依赖（只用以下这些，要加新的先讨论）

| 用途 | 包 |
|---|---|
| 状态管理 | `flutter_riverpod` |
| 路由 | `go_router` |
| HTTP | `dio` |
| WebDAV | `webdav_client` |
| 本地数据库（连接配置、历史、TMDB 缓存） | `drift`（新版自带 sqlite，不再需要 `sqlite3_flutter_libs`） |
| 密钥存储（密码、token、API key） | `flutter_secure_storage` |
| 选本地文件夹 | `file_selector` |
| 窗口尺寸 | `window_manager` |
| 数据模型 | core 里用普通的不可变类，不做代码生成；只有 `app/lib/data/` 里的 drift 用代码生成 |
| 测试用的 mock 服务器 | `shelf`（只在开发时用） |

### 4.2 核心接口（第 0 阶段先定下来，之后各 Agent 只按接口写代码）

```dart
// storage
abstract interface class StorageBackend {
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false});
  Future<void> mkdirs(String dir);
  Future<void> rename(String path, String newName);          // 同目录改名
  Future<void> move(String srcDir, String dstDir, List<String> names);
  Future<void> remove(String dir, List<String> names);
  Future<bool> exists(String path);
}
class RemoteEntry { String path; String name; bool isDir; int size; DateTime? modified; }

// parser
ParsedName parse(String fileName, {List<String> parentDirs = const []});
class ParsedName { String? title; int? year; int? season; List<int> episodes; int? absolute;
  MediaKind kind; /* movie/episode/special/extra/unknown */ String? resolution; String? group;
  String? lang; double confidence; }

// tmdb
abstract interface class MetadataProvider {
  Future<List<Candidate>> search(String query, {MediaKind? kind, int? year});
  Future<ShowDetail> show(int id);                // 包含每季集数
  Future<List<Episode>> season(int id, int season);
  Future<List<EpisodeGroup>> episodeGroups(int id);
  Future<MovieDetail> movie(int id);
}

// plan
RenamePlan buildPlan(ScanResult scan, Map<GroupId, GroupDecision> decisions, PlanOptions opts);
class RenameOp { String src; String dst; OpKind kind; /* move/rename/mkdir/delete */ bool selected; String? warning; }

// exec
Stream<ExecProgress> execute(RenamePlan plan, StorageBackend be, HistoryStore h);
Stream<ExecProgress> undo(BatchId batch, {List<OpId>? only});

// task —— 把以上各步串起来，状态保存到数据库
abstract interface class TaskManager {
  Future<TaskId> submit(ConnectionId conn, List<String> paths, OrganizeMode mode);
  Stream<List<TaskSummary>> watchAll();          // 任务中心订阅这个流
  Future<TaskReview> review(TaskId id);          // 识别结果，给确认页用
  Future<void> updateDecision(TaskId id, GroupId g, GroupDecision d);
  Future<void> run(TaskId id, {bool onlyConfident = false});
  Future<void> cancel(TaskId id);
}
```

### 4.3 执行器规则（防止丢数据）

1. **开始前检查**：所有目标路径不能互相冲突，也不能和已有文件重名。冲突时整个计划不能执行，在界面上标红。
2. **先写日志再操作**：每个操作执行前，先把状态 `pending` 写进 drift，完成后改成 `done` 或 `failed`。程序崩溃后，重新打开可以继续执行或撤销。
3. **操作顺序**：先 mkdir；如果需要跨目录，先在源目录里改成最终的名字，再用 move 移到目标目录。如果改名时源目录里已经有同名文件，就先改成临时名 `.tidyreel-tmp-<id>`。
4. **删除垃圾文件**是单独的步骤，默认不勾选。界面上要说明：网盘的删除会不会进回收站，取决于网盘本身。
5. **限速和重试**：Alist 后端的网盘普遍有频率限制。默认最多 2 个并发，每秒最多 5 个请求；失败后按 1、2、4 秒的间隔退避重试 3 次。
6. **执行后清理**：把变空的源文件夹列出来，让用户选择要不要删除，默认不删。
7. **撤销**：按逆序执行反向操作。如果目标位置已经被别的文件占用，就跳过这一项并报告，不覆盖。

### 4.4 Alist/OpenList 后端

- 登录：`POST /api/auth/login` 拿到 token，存进 secure storage；token 过期后自动重新登录。
- 用到的接口：`/api/fs/list`（扫描时传 `refresh: true`）、`/api/fs/mkdir`、`/api/fs/rename`、`/api/fs/move`、`/api/fs/remove`；如果 `/api/fs/batch_rename` 可用，就用它批量改名。
- ⚠️ 实现前先对照当前 OpenList 文档核对接口和参数。Alist 在 2025 年被转手后，社区分支出了 OpenList，两者的 API 基本兼容，但要分别测试。

### 4.5 文件名解析器的重点用例（fixtures 至少 300 条）

- 欧美 PT/BT：`The.Show.S01E01.1080p.WEB-DL.x264-GRP.mkv`、`Movie.Name.2019.2160p.UHD.BluRay.mkv`、`S01E01-E02`
- 中文：`[字幕组] 繁花 第01集 1080p.mp4`、`繁花.第十二集.mkv`（中文数字）、`【高清】狂飙 EP05.mp4`、`第2季 第3集`
- 动漫：`[Nekomoe] 海贼王 - 1080 [1080p].mkv`（绝对集号）、`01v2`、`OVA`、`SP01`、`特别篇`、`剧场版`
- 只能靠文件夹判断：`权力的游戏/Season 6/05.mkv`、`龙珠Z/291.mp4`
- 干扰项：分辨率、编码、音轨、网址水印（`www.xxx.com`）、日期、`1080p` 被误认成集号、片名里本身有数字（如《2012》《1917》）
- 解析结果都要带**置信度**，低于阈值就交给界面处理，不能瞎猜

### 4.6 TMDB

- 请求都带 `language=zh-CN`；搜不到时再用 `en-US` 搜一次；查询前去掉标点和年份。
- 匹配打分：标题相似度（同时比较简繁和原名）+ 年份 ±1 + 类型是否一致 + 本地集数和 TMDB 集数是否吻合。
- 缓存 v1 先放内存（core 不依赖 drift），每次运行内有效；全局限速每秒 20 个请求。
- 支持在设置里填 Base URL（代理地址）；API key 支持 v3 key 和 v4 read token 两种。

---

## 5. 界面（宽屏布局）

- 最小窗口 1100×700。左侧导航栏 NavigationRail 有四项：**来源**、**任务**（带「待确认」数量的角标）、**命名规则**、**设置**；右侧是内容区。
- **来源页**：连接列表（显示状态）和收藏文件夹；点进一个连接后，同一页面切换成文件浏览器。
- **任务页**：分「进行中」和「已完成」两个标签。每个任务卡片显示：任务 ID、来源路径、阶段进度条（导入 → 识别 → 待确认 → 文件 → 文件夹）、当前状态文字、文件数、文件夹数、字幕数，以及取消、去确认、立即执行、撤销等按钮。
- **识别结果页**（核心页面）用三栏布局：
  - **左栏**：作品列表，分「可整理」和「待手动识别」两个标签。每张作品卡片显示海报、片名和原名、年份、地区、**完整度**（比如「本地 2 季 23 集 / TMDB 2 季 23 集」，缺集标黄），带勾选框。
  - **中栏**：选中作品的明细。顶部按季分标签，标签上显示 `第 1 季 (12/12)`；下面每一行新名在上、原名用灰色小字显示在下，点一行就能单独修正。另有一个「文件夹」标签，预览文件夹会怎么改名或移动。
  - **右栏**：作品操作，包括**纠错**（重新搜 TMDB）、**季集策略**、**剧集组**（TMDB Episode Groups）、集数偏移。
- 「待手动识别」里的条目用搜索框直接搜 TMDB，选中结果后，这个条目移到「可整理」。
- 键盘：↑↓ 切换分组，空格勾选或取消，⌘F 搜索，⌘↩ 执行。
- 状态颜色：绿色表示高置信，黄色表示需要确认，红色表示冲突或识别失败，灰色表示忽略或垃圾文件。
- 所有可点击的目标不小于 40px，方便以后做平板时直接复用。
- 中文为主，界面文字用 `intl` 管理，方便以后加英文。

---

## 6. 里程碑和验收

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **M0 地基** | 仓库、两个工程、核心接口、数据模型、各模块的 Fake 实现、CI（`dart test` + `flutter analyze`） | 用 Fake 能把整个流程从头跑到尾 |
| **M1 核心** | 解析器、TMDB、三个存储后端、策略、模板、执行和撤销 | fixtures 通过率 ≥ 95%；4 种策略测试全部通过；在本地后端上执行后再撤销，文件和原来完全一致 |
| **M2 可用** | 全部界面，并接上真实的 Alist 和 WebDAV | 用真实网盘目录整理完后，VidHub 能正确刮削：电影、普通剧集、动漫拆季各至少 1 部 |
| **M3 打磨** | 垃圾文件规则、Extras、Episode Groups、深色模式、Windows 打包 | Windows 上把同样的流程走一遍 |

---

## 7. 并行开发分工（给 Sonnet Agent 用）

**规则**：M0 由一个 Agent 单独完成（建议用 Opus），先定接口；M0 合并之后，再并行启动下面的 A–F。每个 Agent 用自己的 git worktree 和分支，**只改自己负责的目录**。需要改接口时，停下来报告，由主会话统一修改。

| Agent | 负责目录 | 依赖 | 完成标准 |
|---|---|---|---|
| **A 解析器** | `core/lib/src/parser/`、`core/test/fixtures/` | 无 | ≥300 条用例，通过率 ≥95%，没通过的写进 `KNOWN_FAILURES.md` |
| **B TMDB** | `core/lib/src/tmdb/` | 无 | 用录制好的 HTTP 响应测试；有打分、缓存、限速和代理设置 |
| **C 存储后端** | `core/lib/src/storage/` | 无 | Alist、WebDAV、Local 三个后端都通过同一套测试，Local 跑真实临时目录，远程两个用 mock 服务器 |
| **D 计划生成** | `core/lib/src/plan/` | A 和 B 的接口（用 Fake） | 分组、4 种策略、偏移、模板、字幕、附属文件、垃圾文件分类和冲突检测，全部有单元测试 |
| **E 执行、任务和历史** | `core/lib/src/exec/`、`core/lib/src/task/`、`app/lib/data/` | C 的接口 | 任务状态机、多任务并发、执行、崩溃后继续、撤销、「只看未整理的」查询；用一个「执行到第 N 步时注入失败」的 Fake 测试 |
| **F 界面** | `app/lib/features/**` | 全部接口（用 Fake） | 来源和浏览、任务中心、识别结果、命名规则（带实时预览）、设置，5 个页面都完成，用 Fake 数据就能完整演示；有 widget 测试 |

集成（M2）回到单个会话完成：把 Fake 换成真实实现，连上真实网盘，在 VidHub 上实测。

每个 Agent 的任务说明里要写清楚：负责的目录、要用的接口文件路径、完成标准、「不要改别的目录」，以及「新的依赖必须用 §4.1 里的包」。

---

## 8. 暂不做（v1）

AI 识别、目录监控和自动整理、平板、文件名里写 IMDB 评分（要额外接 OMDb）、远程执行（Filmix 的「本机执行」意味着它还能在别的设备上执行）、签名公证和自动更新、直接对接网盘官方 API、多版本合并命名（等 M2 实测后再决定）。

## 9. 还需要你提供或确认

1. 一份真实的「乱名」文件列表：在 Alist 里把目录树导出，或者截图都行。它会作为解析器的 fixtures 主要来源，比我自己编的用例有用得多。
2. 你用的是 Alist 还是 OpenList，版本号多少；后面挂的是哪些网盘。
