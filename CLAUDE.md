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

## Commits, PRs, releases

Follow `CONTRIBUTING.md`: Conventional Commits (`type(scope): summary`, English,
≤72 chars, checked by `tool/lint_commit.sh`), PR title = squash commit, PR body in
Chinese from the template. Versions come from `app/pubspec.yaml`; cut releases with
`tool/release.sh X.Y.Z` (never push tags unless the user asks).

## Rules for parallel agents

- Touch only the directories your task owns (PLAN §7). Shared files — `lib/src/model/**`,
  any interface file, `pubspec.yaml`, `app/lib/data/providers.dart`, `app/lib/app.dart` —
  are frozen: if you need a change there, stop and report it instead of editing.
- Implement the stub class in your module (it throws `UnimplementedError('Agent X')`);
  don't rename it or change its signature.
- New dependencies need an evaluation first: check maintenance, license, platform support
  (macOS + Windows) and test it against the real use case; report the result before adding it.
- Core models are plain immutable classes (no code generation in core). drift codegen is
  allowed in `app/lib/data/` only.
- UI text is Chinese. Paths in core are '/'-separated absolute strings.
- Never write code that deletes or overwrites user files without an explicit user
  confirmation step and a history record (PLAN §4.3).
- Tests: core logic gets unit tests next to the module (`test/<module>/...`); UI gets widget tests.
