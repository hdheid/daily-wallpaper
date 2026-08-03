#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "用法：bash Scripts/validate-release-notes.sh release-notes/vX.Y.Z.md" >&2
  exit 64
fi

RELEASE_NOTES_PATH="$1"
if [[ ! -f "${RELEASE_NOTES_PATH}" ]]; then
  echo "缺少发布说明：${RELEASE_NOTES_PATH}" >&2
  exit 1
fi

# 固定前三个二级标题，并忽略代码围栏中的示例，防止伪列表绕过校验。
awk '
  BEGIN { current = ""; seen = 0; inFence = 0; failed = 0 }
  /^[[:space:]]*(```|~~~)/ { inFence = !inFence; next }
  inFence { next }
  $0 == "## 新增" { headings["新增"]++; order[++seen] = "新增"; current = "新增"; next }
  $0 == "## 变更" { headings["变更"]++; order[++seen] = "变更"; current = "变更"; next }
  $0 == "## 修复" { headings["修复"]++; order[++seen] = "修复"; current = "修复"; next }
  /^## / {
    if (seen < 3) {
      print "新增、变更、修复必须位于其他二级标题之前" > "/dev/stderr"
      failed = 1
    }
    current = ""
    next
  }
  current != "" && /^- [^[:space:]]/ { bullets[current]++ }
  END {
    required[1] = "新增"; required[2] = "变更"; required[3] = "修复"
    for (position = 1; position <= 3; position++) {
      name = required[position]
      if (headings[name] != 1) {
        print "发布说明必须且只能包含一个 ## " name > "/dev/stderr"
        failed = 1
      }
      if (bullets[name] < 1) {
        print "## " name " 下至少需要一个有效的非空列表项；没有内容时请填写 - 无" > "/dev/stderr"
        failed = 1
      }
      if (order[position] != name) {
        print "发布说明标题必须按照 新增、变更、修复 的顺序排列" > "/dev/stderr"
        failed = 1
      }
    }
    exit failed
  }
' "${RELEASE_NOTES_PATH}"
