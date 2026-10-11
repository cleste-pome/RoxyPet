#!/bin/bash
# Codex notify 桥（洛琪希桌宠）
# 在 ~/.codex/config.toml 里设置：
#   notify = ["/Users/you/.roxy-pet/codex-notify.sh", "turn-ended"]
# 若你已有别的 notify 程序，请在标记处先转发给它，再写桌宠状态。
DIR="$HOME/.roxy-pet"
mkdir -p "$DIR"

# （可选）转发给其它 notify 程序，例如：
# "/path/to/your/notify-program" "$@" >/dev/null 2>&1

printf 'done\n%s\n' "$(date +%s)" > "$DIR/state.codex" 2>/dev/null

python3 - "$@" <<'PY' 2>/dev/null
import sys, json, os
last = ""
for a in sys.argv[1:]:
    try:
        o = json.loads(a)
    except Exception:
        continue
    if isinstance(o, dict):
        v = o.get("last-assistant-message") or o.get("last_assistant_message")
        if v:
            last = v
if last:
    try:
        with open(os.path.expanduser("~/.roxy-pet/last_reply.codex"), "w", encoding="utf-8") as f:
            f.write(str(last)[:150])
    except Exception:
        pass
PY
exit 0
