# Parser known failures

Fixture pass rate: 415 / 415 (100.0%). All five previously documented known
failures have been resolved:

| Input | Resolution |
|---|---|
| `[Group] Title vol.1 [1080p].mkv` | Recognised `vol.N` / `Volume N` markers (when not inside a movie title before a release year like `Kill Bill Vol.1 2003`) so `vol.1` is stripped cleanly from `title`. |
| `1080.mkv` in `海贼王/` | Bare 4-digit non-year stems (`1000..1899`, without `p`/`i`) now resolve as absolute/episode numbers when parent folders supply show/season context; `1080p.mkv` and standalone `1080.mkv` remain untouched. |
| `The Movie 2019.mkv` in `Season 1/Show/` | `"The Movie"` is only stripped as an anime film suffix when a title precedes it (`Pokemon The Movie 2019`); a title starting with `"The Movie"` is preserved. |
| `Blade.Runner.2049.mkv` | Release year candidates are capped at `currentYear + 2`, so futuristic numbers like `2049` stay in the title when no valid release year is present. |
| `Show.S01E01.zh_CN.srt` | Underscores inside locale tags (`zh_CN`, `zh_TW`, `zh_Hans`, `zh_Hant`, `en_US`, `en_GB`) are preserved through separator normalization and normalized to canonical BCP-47 tags by `normalizeLang`. |

## Deliberate behaviours (not failures, but worth knowing)

- Bilingual titles (`老友记.Friends.1994`) return only the CJK part. A short Latin suffix
  (`龙珠 Z`) is kept; a 3+ letter Latin word at the edge is dropped.
- Full-width punctuation is folded to ASCII (`你好，李焕英` -> `你好,李焕英`).
- A bare number with no season anywhere is `absolute`; with a season (file or folder) it
  is an episode. `Title 05.mkv` (no dash) is a low-confidence guess (< 0.5).
- A title that appears only after the episode marker (`S06E05 权力的游戏.mkv`) is treated as an
  episode name, so the title is empty and the planner should fall back to the folder.
- `extraInfo` = resolution + picture (DV/HDR/HDR10+/HLG/IMAX) + audio (Atmos/TrueHD/DTS-HD).
  Source and codec are left out.
- Rules borrowed from Jellyfin (Emby.Naming) and Sonarr: episode ranges (`EP01-EP02`,
  `第01-03集`), mini-series `1of6`, and air-dated names (`向往的生活.20240503`) which carry
  `airDate` and are matched to a TMDB episode by date in the planner.
- Bare numbered files (`01.mkv`) stay low-confidence on their own; the planner trusts them
  when a group has a run of two or more distinct numbers. Quality folders (`4K`, `2160p`,
  `蓝光`…) never count as the show folder.
