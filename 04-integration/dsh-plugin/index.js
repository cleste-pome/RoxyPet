/**
 * dsh-plugin-roxy — DeepSeek Harness ↔ 洛琪希桌宠 桥
 *
 * 宿主侧只做三件事，全部通过 ~/.roxy-pet 下的文件交接，不碰 dsh 会话与工作区：
 *   1. 把 turn/tool/assistant 事件写成 state.dsh / last_reply.dsh
 *   2. 把 approval/request 转成 dsh/approval.json，等桌宠写回 dsh/approval-reply.json
 *   3. 桌宠不在线（心跳过期）时一律 next()，把批准交还给 dsh 自己的界面
 *
 * 安装：dsh plugin --profile desktop add <本目录>
 */

import { mkdir, readFile, writeFile, rename, unlink, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

export const name = 'dsh-plugin-roxy'

const BASE = join(homedir(), '.roxy-pet')
const DIR = join(BASE, 'dsh')
const STATE_TXT = join(BASE, 'state.dsh')
const REPLY_TXT = join(BASE, 'last_reply.dsh')
const DETAIL_JSON = join(DIR, 'state.json')
const APPROVAL_JSON = join(DIR, 'approval.json')
const APPROVAL_REPLY = join(DIR, 'approval-reply.json')
const HEARTBEAT = join(DIR, 'roxy-heartbeat')

const HEARTBEAT_FRESH_MS = 15000
const DEFAULT_TIMEOUT_MS = 120000

async function atomicWrite(path, text) {
  const tmp = `${path}.tmp-${process.pid}`
  await writeFile(tmp, text, 'utf8')
  await rename(tmp, path)
}

async function tryUnlink(path) {
  try { await unlink(path) } catch { /* absent is fine */ }
}

async function readJson(path) {
  try { return JSON.parse(await readFile(path, 'utf8')) } catch { return null }
}

async function heartbeatFresh() {
  try {
    const s = await stat(HEARTBEAT)
    return Date.now() - s.mtimeMs < HEARTBEAT_FRESH_MS
  } catch {
    return false
  }
}

function textFromMessage(message) {
  if (message === null || typeof message !== 'object' || !Array.isArray(message.content)) return ''
  const parts = []
  for (const block of message.content) {
    if (block === null || typeof block !== 'object') continue
    if (block.type === 'text' && typeof block.text === 'string') parts.push(block.text)
    else if (typeof block.text === 'string' && block.type === undefined) parts.push(block.text)
  }
  return parts.join('\n').trim()
}

class Bridge {
  constructor(config = {}) {
    this.config = config
    this.status = 'idle'
    this.lastReply = ''
    this.lastTool = ''
    this.sessionId = ''
    this.pendingId = null
    this.timeoutMs = Number.isFinite(config.approvalTimeoutMs) && config.approvalTimeoutMs > 0
      ? config.approvalTimeoutMs
      : DEFAULT_TIMEOUT_MS
  }

  async init() {
    try {
      await mkdir(DIR, { recursive: true })
      await tryUnlink(APPROVAL_JSON)
      await tryUnlink(APPROVAL_REPLY)
      await this.persist('idle')
    } catch { /* dsh may be running in a sandbox; never fail the host */ }
  }

  async persist(status) {
    this.status = status
    const now = Date.now()
    try {
      await atomicWrite(STATE_TXT, `${status}\n${now}\n`)
      await atomicWrite(DETAIL_JSON, JSON.stringify({
        status,
        sessionId: this.sessionId,
        lastTool: this.lastTool,
        lastReply: this.lastReply.slice(0, 2000),
        updatedAt: now,
      }, null, 2))
    } catch { /* ignore */ }
  }

  async onSessionEvent(session, event) {
    const type = event?.type
    if (typeof type !== 'string') return
    const data = event.data !== null && typeof event.data === 'object' ? event.data : {}
    const sid = session?.header?.id ?? session?.id
    if (typeof sid === 'string' && sid !== '') this.sessionId = sid

    switch (type) {
      case 'turn/start':
        await this.persist('working')
        break
      case 'tool/call':
        this.lastTool = typeof data.name === 'string' && data.name !== ''
          ? data.name
          : (typeof data.toolName === 'string' ? data.toolName : 'tool')
        await this.persist('working')
        break
      case 'assistant/message': {
        const text = textFromMessage(data.message)
        if (text !== '') {
          this.lastReply = text
          try { await atomicWrite(REPLY_TXT, text) } catch { /* ignore */ }
        }
        break
      }
      case 'approval/asked':
        await this.persist('working')
        break
      case 'approval/decided':
        await this.persist('working')
        break
      case 'turn/end': {
        let raw = ''
        try { raw = JSON.stringify(data) } catch { raw = '' }
        const failed = /(?:error|abort|cancel|interrupt|fail)/i.test(raw)
        await this.persist(failed ? 'notice' : 'done')
        break
      }
      default:
        break
    }
  }

  async onAgentError(error) {
    const text = error instanceof Error ? error.message : String(error ?? '')
    if (text !== '') {
      this.lastReply = text
      try { await atomicWrite(REPLY_TXT, text) } catch { /* ignore */ }
    }
    await this.persist('notice')
  }

  /** Return an ApprovalOutcome, or null to delegate to the next answerer. */
  async askApproval(request) {
    if (this.config.enabled === false) return null
    if (!(await heartbeatFresh())) return null // Roxy not running → let dsh UI decide

    const id = randomUUID()
    const now = Date.now()
    const payload = {
      id,
      toolName: typeof request.toolName === 'string' && request.toolName !== '' ? request.toolName : 'tool',
      reason: typeof request.reason === 'string' ? request.reason : '',
      callId: typeof request.callId === 'string' ? request.callId : '',
      sessionId: request.agent?.session?.id ?? this.sessionId ?? '',
      createdAt: now,
      expiresAt: now + this.timeoutMs,
    }
    this.pendingId = id
    try {
      await tryUnlink(APPROVAL_REPLY)
      await atomicWrite(APPROVAL_JSON, JSON.stringify(payload, null, 2))
    } catch {
      this.pendingId = null
      return null
    }

    const deadline = now + this.timeoutMs
    const signal = request.signal
    while (Date.now() < deadline) {
      if (signal?.aborted) {
        await this.clearPending()
        return 'cancelled'
      }
      const reply = await readJson(APPROVAL_REPLY)
      if (reply !== null && reply.id === id) {
        await tryUnlink(APPROVAL_REPLY)
        await this.clearPending()
        return reply.decision === 'allow' ? 'allowed-once' : 'rejected'
      }
      // Roxy disappeared mid-question: withdraw and delegate rather than block dsh.
      if (Date.now() - now > 5000 && !(await heartbeatFresh())) {
        await this.clearPending()
        return null
      }
      await new Promise((resolve) => setTimeout(resolve, 250))
    }
    await this.clearPending()
    return 'cancelled'
  }

  async clearPending() {
    this.pendingId = null
    await tryUnlink(APPROVAL_JSON)
  }

  async shutdown() {
    await this.clearPending()
    // Keep a terminal 'done'/'notice' so the pet can announce it; only an
    // interrupted 'working' session collapses back to idle.
    if (this.status === 'working') await this.persist('idle')
  }
}

/**
 * Cordis plugin entry.
 * @param ctx - host plugin context.
 * @param config - { enabled?, approvalTimeoutMs? }.
 */
export function apply(ctx, config = {}) {
  const bridge = new Bridge(config)
  void bridge.init()

  ctx.effect(() => {
    const off = ctx.on('session/event', (session, event) => {
      void bridge.onSessionEvent(session, event)
    })
    return () => { off() }
  }, 'dsh-plugin-roxy: session feed')

  ctx.effect(() => {
    const off = ctx.on('approval/request', (request, next) => {
      return bridge.askApproval(request).then((outcome) => outcome ?? next())
    })
    return () => { off() }
  }, 'dsh-plugin-roxy: approval answerer')

  ctx.effect(() => {
    const off = ctx.on('agent/error', ({ error }) => {
      void bridge.onAgentError(error)
    })
    return () => { off() }
  }, 'dsh-plugin-roxy: error feed')

  ctx.effect(() => () => { void bridge.shutdown() }, 'dsh-plugin-roxy: cleanup')
}
