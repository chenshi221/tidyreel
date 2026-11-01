#!/bin/sh
# Cut a release locally: bump the version, write CHANGELOG.md from the commits
# since the last tag, commit "chore(release): vX.Y.Z" and tag it. Never pushes.
# Usage: tool/release.sh 0.2.0
set -e
export PATH=/opt/homebrew/opt/git/bin:$PATH
cd "$(dirname "$0")/.."

new="$1"
echo "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "用法：tool/release.sh X.Y.Z（语义化版本，不带 v）" >&2
  exit 1
}
git rev-parse -q --verify "refs/tags/v$new" >/dev/null && {
  echo "标签 v$new 已存在" >&2
  exit 1
}
[ -z "$(git status --porcelain)" ] || {
  echo "工作区有未提交的改动，先提交或暂存" >&2
  exit 1
}

old_build=$(sed -n 's/^version: [0-9.]*+\([0-9]*\)$/\1/p' app/pubspec.yaml)
build=$(( ${old_build:-0} + 1 ))
prev=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
range="${prev:+$prev..}HEAD"

# "type(scope)!: summary" -> "- **scope**: summary", grouped by type.
section() {
  lines=$(git log --no-merges --reverse --format='%s' "$range" |
    grep -E "^($2)(\([a-z0-9-]+\))?!?: " |
    grep -v '^chore(release)' |
    sed -E 's/^[a-z]+\(([a-z0-9-]+)\)!?: (.*)$/- **\1**：\2/; s/^[a-z]+!?: (.*)$/- \1/' || true)
  [ -n "$lines" ] && printf '### %s\n\n%s\n\n' "$1" "$lines"
  return 0
}
breaking=$(git log --no-merges --format='%s%n%b' "$range" |
  grep -E '^[a-z]+(\([a-z0-9-]+\))?!: |^BREAKING CHANGE: ' |
  sed -E 's/^BREAKING CHANGE: /- /; s/^[a-z]+(\([a-z0-9-]+\))?!: /- /' || true)

entry=$(
  printf '## [%s] - %s\n\n' "$new" "$(date +%Y-%m-%d)"
  [ -n "$breaking" ] && printf '### ⚠️ 不兼容改动\n\n%s\n\n' "$breaking"
  section '新功能' feat
  section '修复' fix
  section '性能' perf
  section '界面' ui
  section '其他' 'refactor|build|ci|docs|test|chore|revert'
)

header='# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。由 `tool/release.sh` 根据提交说明生成，发布前可以手动润色。
'
old=""
[ -f CHANGELOG.md ] && old=$(sed '1,/^## \[/{/^## \[/!d;}' CHANGELOG.md)
printf '%s\n%s\n%s\n' "$header" "$entry" "$old" > CHANGELOG.md

sed -i.bak -E "s/^version: .*/version: $new+$build/" app/pubspec.yaml && rm app/pubspec.yaml.bak
printf "// Written by tool/release.sh from app/pubspec.yaml; tool/check.sh keeps them in sync.\nconst appVersion = '%s';\nconst appBuild = %s;\n" "$new" "$build" > app/lib/version.dart

git add CHANGELOG.md app/pubspec.yaml app/lib/version.dart
git commit -q -m "chore(release): v$new"
git tag -a "v$new" -m "理片 Tidyreel v$new"
echo "已提交并打标签 v$new（构建号 $build）。检查 CHANGELOG.md 后再推送："
echo "  git push && git push origin v$new"
