#!/bin/bash
# Claude Code PermissionRequest -> Roxy 桌宠审批桥
# 只在 Roxy 正在运行、且任务执行器=Claude Code 时接管；
# 超时 / Roxy 没开 / 没选中 Claude Code → 不输出 JSON，Claude Code 会显示终端原来的权限提示。
set -u
base="$HOME/.roxy-pet/claude"
reqdir="$base/requests"
repdir="$base/replies"
mkdir -p "$reqdir" "$repdir" 2>/dev/null

input="$(cat 2>/dev/null)"
[ -n "$input" ] || exit 0

pgrep -f 'MacOS/Roxy' >/dev/null 2>&1 || exit 0
h="$(defaults read local.roxypet.desktop roxyHarness 2>/dev/null || echo claude)"
[ "$h" = "claude" ] || exit 0

# 清掉十分钟前的旧回复，避免目录堆积
find "$repdir" -type f -name '*.json' -mmin +10 -delete 2>/dev/null || true

id="$(printf '%s' "$input" | python3 -c '
import sys, json, os, time, uuid
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
tool = d.get("tool_name") or "tool"
ti = d.get("tool_input") or {}
if tool == "Bash":
    s = ti.get("command", "")
elif tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
    s = ti.get("file_path", "")
elif tool == "WebFetch":
    s = ti.get("url", "")
else:
    try:
        s = json.dumps(ti, ensure_ascii=False)
    except Exception:
        s = str(ti)
s = str(s).strip()[:800]
rid = uuid.uuid4().hex
req = {"id": rid, "tool": tool, "summary": s,
       "sessionId": d.get("session_id", ""),
       "createdAt": time.time(), "expiresAt": time.time() + 40}
p = os.path.expanduser("~/.roxy-pet/claude/requests/" + rid + ".json")
tmp = p + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(req, f, ensure_ascii=False)
os.replace(tmp, p)
print(rid)
' 2>/dev/null)"
[ -n "$id" ] || exit 0

deadline=$(( $(date +%s) + 35 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$repdir/$id.json" ]; then
    dec="$(python3 -c '
import json,sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("decision", ""))
except Exception:
    print("")
' "$repdir/$id.json" 2>/dev/null)"
    rm -f "$repdir/$id.json" "$reqdir/$id.json"
    if [ "$dec" = "allow" ]; then
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    elif [ "$dec" = "deny" ]; then
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"用户在桌宠里拒绝了这次操作"}}}'
    fi
    exit 0
  fi
  sleep 0.25
done

rm -f "$reqdir/$id.json"
exit 0
