#!/bin/bash
# 洛琪希桌宠 ↔ Claude Code 状态桥
# 用法: hook.sh working|done|notice|idle
# 写 ~/.roxy-pet/state（状态+时间戳）；done 时另把最后一条回复摘要存到 last_reply、
# 会话 ID 存到 last_session（供她转述 / 点击气泡接续会话）
# 多开 Claude Code 时，每个会话另写一份 state.claude.<session_id>，
# 避免别的会话的 working / notice 把本会话刚写下的 done 覆盖掉。
# 永远 exit 0，绝不阻塞 Claude Code。
state="${1:-idle}"
dir="$HOME/.roxy-pet"
mkdir -p "$dir" 2>/dev/null

# hooks 通过 stdin 传入 JSON（所有事件都带 session_id）；只读一次，后面复用。
input="$(cat 2>/dev/null)"
sid="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("session_id") or "")
' 2>/dev/null)"
safe_sid="$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-')"

write_state() {
  local file="$1"
  printf '%s\n%s\n' "$state" "$(date +%s)" > "$dir/$file" 2>/dev/null
}

write_tty() {
  local tty_name="" cur=$$ t
  for i in 1 2 3 4 5; do
    t="$(ps -o tty= -p "$cur" 2>/dev/null | tr -d ' ')"
    if [ -n "$t" ] && [ "$t" != "??" ]; then tty_name="$t"; break; fi
    cur="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')"
    { [ -z "$cur" ] || [ "$cur" = "0" ] || [ "$cur" = "1" ]; } && break
  done
  printf '%s\n%s\n%s\n%s\n' "$tty_name" "${TERM_PROGRAM:-}" "${TERM_SESSION_ID:-${ITERM_SESSION_ID:-}}" "$(date +%s)" > "$dir/last_tty" 2>/dev/null
}

if [ "$state" = "notice" ]; then
  # 权限确认 / 等待输入的提示文字原样交给桌宠，不再只说一句通用台词。
  write_tty
  if [ -n "$sid" ]; then printf '%s' "$sid" > "$dir/last_session" 2>/dev/null; fi
  printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
msg = (d.get("message") or d.get("title") or "").strip()
if msg:
    print(msg[:300])
' > "$dir/last_notice" 2>/dev/null
fi

if [ "$state" = "done" ]; then
  write_tty
  # 先把回复与会话写盘，再写状态：桌宠看到 done 时，last_reply 一定已经存在。
  printf '%s' "$input" | python3 -c '
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

# 每个会话单独一份；本会话的 done 不会被其他会话的 working / notice 覆盖。
# idle 不覆盖会话文件：Stop 之后紧接 SessionEnd 时，桌宠可能还没来得及读到 done。
if [ -n "$safe_sid" ] && [ "$state" != "idle" ]; then
  write_state "state.claude.$safe_sid"
fi
# 会话文件只保留最近两天，避免目录无限增长后被桌宠每 0.25 秒扫描。
find "$dir" -maxdepth 1 -type f -name 'state.claude.*' -mtime +2 -delete 2>/dev/null || true
write_state "state.claude"
write_state "state"
exit 0
