# 理片 Tidyreel

A desktop app (macOS first, Windows next) that renames and reorganizes downloaded movies
and TV shows on Alist / OpenList, WebDAV or local folders, so media players such as
VidHub can identify and scrape them correctly.

把网盘（Alist / OpenList、WebDAV）或本地文件夹里命名混乱的影视资源，整理成 VidHub 等播放器能正确刮削的命名和目录结构。

## What it does

- Scans selected folders, parses messy file names (Western scene names, Chinese names,
  anime absolute numbering), and groups files by title.
- Matches each title against TMDB to get the canonical title, year and season layout.
- Shows a preview of every rename (`原名 → 新名`) for review; nothing is changed until you
  confirm.
- Season strategies for anime: split one long season into TMDB seasons, or merge seasons.
- Subtitles follow their video; specials go to `Season 00`; extras to `Extras/`.
- Every executed batch is recorded and can be undone.

## Status

Early development, personal use. See [PLAN.md](PLAN.md) for the full design.

## Build

Requires Flutter (stable) and Xcode on macOS.

```bash
cd app
flutter run -d macos
```

Checks for both packages: `tool/check.sh`.

## TMDB

Users enter their own TMDB API key in Settings. Requests go directly from the app to TMDB
(or to a proxy URL the user configures); no data is sent anywhere else.

This product uses the TMDB API but is not endorsed or certified by TMDB.

## Credits

The renaming approach is inspired by [mnamer](https://github.com/jkwill87/mnamer)
(MIT, see [LICENSES/mnamer-MIT.txt](LICENSES/mnamer-MIT.txt)). Tidyreel is a separate
implementation in Dart.
