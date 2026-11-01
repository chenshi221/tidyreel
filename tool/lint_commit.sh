#!/bin/sh
# Checks one commit subject (or PR title) against CONTRIBUTING.md:
#   type(scope)!: summary   — English, imperative, at most 72 characters.
# Usage: tool/lint_commit.sh "feat(review): pick episodes from TMDB"
subject="$1"
case "$subject" in
  Merge\ *|Revert\ *|fixup!\ *|squash!\ *|amend!\ *) exit 0 ;;
esac
types='feat|fix|perf|refactor|ui|test|docs|ci|build|chore|revert'
if ! printf '%s' "$subject" | grep -Eq "^($types)(\([a-z0-9-]+\))?!?: [^ ].*[^.]$"; then
  echo "✗ 不符合提交规范：$subject" >&2
  echo "  格式：类型(范围): 说明，例如 feat(review): pick episodes from TMDB" >&2
  echo "  类型：$(echo "$types" | tr '|' ' ')；结尾不加句号。详见 CONTRIBUTING.md" >&2
  exit 1
fi
if [ "$(printf '%s' "$subject" | wc -m)" -gt 72 ]; then
  echo "✗ 标题超过 72 个字符：$subject" >&2
  exit 1
fi
