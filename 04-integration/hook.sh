#!/bin/bash
# 洛琪希桌宠 ↔ Claude Code 状态桥
# 用法: hook.sh working|done|notice|idle
# 写 ~/.roxy-pet/state（状态+时间戳）；done 时另把最后一条回复摘要存到 last_reply、
# 会话 ID 存到 last_session（供她转述 / 点击气泡接续会话）
# 永远 exit 0，绝不阻塞 Claude Code。
state="${1:-idle}"
dir="$HOME/.roxy-pet"
mkdir -p "$dir" 2>/dev/null
tmp="$dir/.state.tmp.$$"
printf '%s\n%s\n' "$state" "$(date +%s)" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/state" 2>/dev/null

if [ "$state" = "done" ]; then
  tty_name=""
  cur=$$
  for i in 1 2 3 4 5; do
    t="$(ps -o tty= -p "$cur" 2>/dev/null | tr -d ' ')"
    if [ -n "$t" ] && [ "$t" != "??" ]; then tty_name="$t"; break; fi
    cur="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')"
    { [ -z "$cur" ] || [ "$cur" = "0" ] || [ "$cur" = "1" ]; } && break
  done
  printf '%s\n%s\n%s\n%s\n' "$tty_name" "${TERM_PROGRAM:-}" "${TERM_SESSION_ID:-${ITERM_SESSION_ID:-}}" "$(date +%s)" > "$dir/last_tty" 2>/dev/null
  python3 -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sid = d.get("session_id") or ""
if sid:
    try:
        with open(os.path.expanduser("~/.roxy-pet/last_session"), "w", encoding="utf-8") as f:
            f.write(sid)
    except Exception:
        pass
tp = d.get("transcript_path") or ""
msg = ""
if tp and os.path.exists(tp):
    try:
        lines = open(tp, encoding="utf-8", errors="ignore").read().splitlines()
        for ln in reversed(lines[-300:]):
            try:
                obj = json.loads(ln)
            except Exception:
                continue
            if obj.get("type") == "assistant":
                c = (obj.get("message") or {}).get("content")
                if isinstance(c, list):
                    texts = [x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text"]
                    msg = " ".join(t for t in texts if t).strip()
                elif isinstance(c, str):
                    msg = c.strip()
                if msg:
                    break
    except Exception:
        pass
if msg:
    with open(os.path.expanduser("~/.roxy-pet/last_reply"), "w", encoding="utf-8") as f:
        f.write(msg[:150])
' 2>/dev/null
fi
exit 0
