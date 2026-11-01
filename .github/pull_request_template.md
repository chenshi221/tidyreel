<!--
标题沿用提交规范：类型(范围): 说明（英文、祈使句、≤72 字符），例如
  feat(review): pick episodes from TMDB
合并方式是 squash，标题就是最终写进 main 的提交说明。详见 CONTRIBUTING.md。
-->

## 概要

<!-- 为什么改、解决了什么问题，一两句话。关联 issue：Closes #… -->

## 改动

-

## 怎么测的

<!-- 自动测试之外，手动在哪个连接（Alist / WebDAV / 本地）上验证了什么 -->

-

## 截图

<!-- 界面改动请附前后对比；没有就删掉这一节 -->

## 风险与回滚

<!-- 会不会改动用户文件、数据库或 prefs.json 的格式；出问题怎么撤回 -->

## 检查

- [ ] `tool/check.sh` 通过
- [ ] 没有提交密钥、token 或 `app/tmdb.local.json`
- [ ] 会改动或删除用户文件的地方有确认步骤和历史记录（PLAN §4.3）
- [ ] 界面文字是中文
- [ ] 需要写进更新日志的改动，提交说明已经写清楚（`tool/release.sh` 会据此生成 CHANGELOG）
