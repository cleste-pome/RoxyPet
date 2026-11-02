# dsh-plugin-roxy

DeepSeek Harness ↔ 洛琪希桌宠 的桥插件。宿主侧只读写 `~/.roxy-pet` 下的文件，不碰 dsh 会话与工作区。

## 它做什么

| 能力 | 机制 |
|---|---|
| 状态联动 | 监听 `session/event` 的 `turn/start`、`tool/call`、`turn/end`，写 `~/.roxy-pet/state.dsh`（`working` / `done` / `notice` + 时间戳）|
| 回复转述 | 监听 `assistant/message`，把文本写进 `~/.roxy-pet/last_reply.dsh` |
| 权限批准 | 监听 `approval/request`，写 `~/.roxy-pet/dsh/approval.json`；桌宠写回 `approval-reply.json`（`allow` / `deny`）后返回 `allowed-once` / `rejected` |

## 安全闸门

- 桌宠每 5 秒写一次 `~/.roxy-pet/dsh/roxy-heartbeat`；**心跳不新鲜时插件直接 `next()`**，把审批交还给 dsh 自己的界面
- 等待审批默认 120 秒（可在插件配置里改 `approvalTimeoutMs`）；超时返回 `cancelled`（fail-closed）
- 桌宠中途消失：插件撤下问题并交还 dsh UI，不会卡住会话
- 只做一次性授权（`allowed-once`），不实现“永远允许”

## 安装

```sh
# 桌面版
dsh plugin --profile desktop add /path/to/RoxyPet-GitHub/04-integration/dsh-plugin

# Web 版
dsh plugin --profile web add /path/to/RoxyPet-GitHub/04-integration/dsh-plugin
```

装完重启对应的 dsh 进程/应用。卸载：

```sh
dsh plugin --profile desktop remove dsh-plugin-roxy
```

## 配置

插件配置（profile 的 `cordis.patch.yml` 或 dsh 设置）：

| 字段 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 关掉后完全不接管审批 |
| `approvalTimeoutMs` | `120000` | 等桌宠回答的最长时间 |

## 文件协议

| 文件 | 方向 | 内容 |
|---|---|---|
| `~/.roxy-pet/state.dsh` | 插件 → 桌宠 | 第一行状态、第二行毫秒时间戳 |
| `~/.roxy-pet/last_reply.dsh` | 插件 → 桌宠 | 最近一条 assistant 文本 |
| `~/.roxy-pet/dsh/state.json` | 插件 → 桌宠 | 同上，附带 sessionId / lastTool / updatedAt |
| `~/.roxy-pet/dsh/roxy-heartbeat` | 桌宠 → 插件 | 桌宠存活心跳 |
| `~/.roxy-pet/dsh/approval.json` | 插件 → 桌宠 | `{id, toolName, reason, callId, sessionId, createdAt, expiresAt}` |
| `~/.roxy-pet/dsh/approval-reply.json` | 桌宠 → 插件 | `{id, decision: "allow" \| "deny"}` |

所有写入都是临时文件 + rename 的原子写，读方不会看到半个 JSON。

## 限制

- 只桥接 `approval/request` 的一次性授权；dsh 的 `never` 策略会先于任何应答者拒绝，插件无法绕过
- 多个 dsh 会话同时运行时，状态文件只保留最近一个会话的状态
- dsh 仍处于 developer preview，事件名与审批 seam 可能随版本变化；升级 dsh 后请回归一次本插件
