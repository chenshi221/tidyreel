# 理片 Tidyreel

100% pure native Swift macOS app (`SwiftUI` + `AppKit`, zero external dependencies) that renames
and reorganizes media on Alist/OpenList, WebDAV, SMB, and local folders so VidHub / Infuse /
Plex / Jellyfin can scrape it cleanly.

## Layout (`Package.swift`)

- `Sources/TidyreelModels/` — Shared immutable `Sendable` value models, core protocols, codecs, l10n, text utilities, and test fakes.
- `Sources/TidyreelParser/` — Pre-compiled regex filename/folder parser, Chinese numerals, and `looksOrganized` detector.
- `Sources/TidyreelProbe/` — Binary EBML/MKV/WebM & ISO-BMFF/MP4/MOV header range prober (Dolby Vision, HDR10+, Atmos).
- `Sources/TidyreelMetadata/` — TMDB, Bangumi (`bgm.tv`), and AniList clients, candidate scoring, and actor rate limiting.
- `Sources/TidyreelStorage/` — `LocalBackend`, `AlistBackend`, `WebDAVBackend`, native macOS `SMBBackend` (`NetFS`), `CachedBackend`, and `ThrottledBackend`.
- `Sources/TidyreelPlanner/` — `AnchorRecognizer`, season strategies, naming template engine, follower matcher, Kodi/VidHub NFO scraper, and `DefaultPlanner`.
- `Sources/TidyreelExecution/` — WAL-backed `DefaultExecutor` (with reverse undo & crash recovery) and lazy-memory `DefaultTaskManager`.
- `Sources/TidyreelPersistence/` — Background-actor `SQLite3` database (`v1..v5 -> v6`), stores, `SQLiteTmdbCache`, and POSIX `0600` `FileSecretStore`.
- `Sources/TidyreelDesign/` — Xuan-paper & Ink monochrome palette, 0ms instant-hover components, `ImageIO` downsampled `ArtworkCache`, and off-main-thread `OrganicLayout` Voronoi engine.
- `Sources/TidyreelServices/` — `@Observable @MainActor AppStore`, `SizeScannerActor`, `HealthScannerActor`, and `ScanPreviewService`.
- `Sources/TidyreelSourcesUI/`, `TidyreelReviewUI/`, `TidyreelTasksUI/`, `TidyreelHealthUI/`, `TidyreelSettingsUI/` — Modular native macOS SwiftUI feature targets.
- `Sources/TidyreelApp/` — macOS app shell & executable entrypoint (`tidyreel`).
- `Resources/` — `Info.plist`, `Tidyreel.entitlements`, and `AppIcon.icns`.

## Commands

- Verify everything (version sync + `-warnings-as-errors` build + parallel tests): `tool/check.sh`
- Build signed macOS `.app` bundle (`build/Release/tidyreel.app`): `tool/build_macos.sh release`
- Prefix commands with `export PATH=/opt/homebrew/opt/git/bin:$PATH` when git is needed.

## Safety & Performance Invariants

- Never delete or overwrite user files without an explicit confirmation step and a WAL history record.
- Keep heavy work off `@MainActor`: SQLite queries, JSON decoding, directory scanning, MediaProbe range reads, ImageIO thumbnail downsampling, and Voronoi layout all run on background actors/tasks.
- Keep historical `ScanResult` payloads lazy (`SQLiteTaskStore.loadSummaries()` on startup; `loadReview(id:)` on demand and evicted once finished).
