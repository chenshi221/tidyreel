# 理片 Tidyreel

原生 macOS 影视整理软件（100% 纯 Swift / SwiftUI + AppKit，零第三方依赖），把 Alist / OpenList、WebDAV、SMB 或本地文件夹里命名混乱的影视资源，整理成 VidHub、Infuse、Plex、Jellyfin 能精准识别与刮削的目录和命名结构。

## 核心能力

- **多来源直连**：支持 Alist / OpenList（含目录访问密码）、WebDAV、macOS 原生 SMB 共享与本地文件夹，内置仓库有机地图（Voronoi 容量与整理度可视化）。
- **本地规则 + 多源识别**：支持欧美 PT/BT、中文数词、番剧绝对集号、蓝光/DVD 原盘目录识别，结合 TMDB、Bangumi 与 AniList 自动补全中英文标题与剧集结构。
- **按需容器头探测**：纯 Swift 分段读取 MKV/MP4 文件头（≤512 KB），免外部依赖识别分辨率、杜比视界（Dolby Vision）、HDR10+、Atmos 等规格。
- **三栏可视化核对与安全执行**：支持季集拆分/合并策略、字幕与音轨跟随、NFO 与海报刮削、WAL 预写日志防丢数据，以及整批或单文件一键撤销。
- **媒体库体检**：零 TMDB 请求快速排查重复片源（画质排序对比）、缺失 NFO/海报（一键仅刮削补全）及垃圾文件与空目录。

## 构建与检查

环境要求：macOS 14+ 与 Xcode（Apple Silicon `arm64`）。

```bash
# 运行零警告编译检查与全部单元测试
./tool/check.sh

# 打包原生 Release 应用（输出至 build/Release/tidyreel.app）
./tool/build_macos.sh release
open build/Release/tidyreel.app
```

如需在打包时内置默认只读 TMDB Token，可将 `tmdb.local.json.example` 复制为仓库根目录 `tmdb.local.json`（已配置 `.gitignore`），构建脚本会自动注入应用包；用户在「设置」中填写的 API Key 始终优先。

## 致谢与声明

重命名思路参考了 [mnamer](https://github.com/jkwill87/mnamer)（MIT 协议，见 [LICENSES/mnamer-MIT.txt](LICENSES/mnamer-MIT.txt)）。本软件使用 TMDB API，但未获得 TMDB 官方认证或背书。
