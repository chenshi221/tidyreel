#!/bin/sh
# Use the repository's hooks (tool/hooks) for this clone.
cd "$(dirname "$0")/.."
git config core.hooksPath tool/hooks
echo "已启用 tool/hooks（commit-msg 会检查提交规范）"
