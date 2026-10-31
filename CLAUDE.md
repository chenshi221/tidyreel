# 理片 Tidyreel

Flutter desktop app (macOS first, Windows second) that renames and reorganizes media on
Alist / WebDAV / local folders so VidHub can scrape it. The spec is `PLAN.md` — read the
sections your task names before writing code.

## Layout

- `packages/tidyreel_core/` — pure Dart engine, no Flutter. Public API: `lib/tidyreel_core.dart`.
  Fakes for tests and UI demos: `lib/testing.dart`.
- `app/` — Flutter UI. All engine access goes through `app/lib/data/providers.dart`.

## Commands

- Everything: `tool/check.sh` (format, analyze, test for both packages). Must pass before you finish.
- `/usr/bin/git` fails until the Xcode license is accepted; prefix with
  `export PATH=/opt/homebrew/opt/git/bin:$PATH` (flutter needs this too).

## Rules for parallel agents

- Touch only the directories your task owns (PLAN §7). Shared files — `lib/src/model/**`,
  any interface file, `pubspec.yaml`, `app/lib/data/providers.dart`, `app/lib/app.dart` —
  are frozen: if you need a change there, stop and report it instead of editing.
- Implement the stub class in your module (it throws `UnimplementedError('Agent X')`);
  don't rename it or change its signature.
- No new dependencies beyond what the pubspecs already list.
- Core models are plain immutable classes (no code generation in core). drift codegen is
  allowed in `app/lib/data/` only.
- UI text is Chinese. Paths in core are '/'-separated absolute strings.
- Never write code that deletes or overwrites user files without an explicit user
  confirmation step and a history record (PLAN §4.3).
- Tests: core logic gets unit tests next to the module (`test/<module>/...`); UI gets widget tests.
