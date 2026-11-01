# Parser known failures

Fixture pass rate: 406 / 411 (98.8%). The five misses below carry a `known:` reason in
`fixtures.dart`; the test still runs them and prints them, but does not fail on them.
A non-`known` miss fails the test.

| Input | Expected | Got | Why |
|---|---|---|---|
| `[Group] Title vol.1 [1080p].mkv` | title `Title` | `Title vol` | `vol.N` is not a recognised marker; the `1` is left as a stray number. |
| `1080.mkv` in `海贼王/` | title `海贼王`, absolute 1080 | title `1080` | A bare 4-digit stem is indistinguishable from a resolution/year; only `- 1080` (dash form) is read as an episode. |
| `The Movie 2019.mkv` in `Season 1/Show/` | title `The Movie` | title `2019` | "The Movie" is a strip-able keyword (`... The Movie` anime films); a real title with that phrase loses it. |
| `Blade.Runner.2049.mkv` | title `Blade Runner 2049`, no year | title `Blade Runner`, year 2049 | A year-like number is a year when it is the only one. With a second real year (`...2049.2017`) it stays in the title. |
| `Show.S01E01.zh_CN.srt` | lang `zh_CN` | `zh-CN` | Separators are normalised before the language is read, so the underscore is lost. |

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
