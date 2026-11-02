/**
 * dsh-plugin-roxy — DeepSeek Harness ↔ 洛琪希桌宠 桥
 *
 * 宿主侧只做四件事，全部通过 ~/.roxy-pet 下的文件交接，不碰 dsh 会话与工作区：
 *   1. 把 turn/tool/assistant 事件写成 state.dsh / last_reply.dsh
 *   2. 把 approval/request 转成 dsh/approval.json，等桌宠写回 dsh/approval-reply.json
 *   3. 把双向对话（user/message + assistant/message）追加到 dsh/conversation.json，供桌宠「记录」窗口展示
 *   4. 把每轮 token 用量写到 dsh/usage.json（桌宠读来显示花费；不含正文）
 * 桌宠不在线（心跳过期）时一律 next()，把批准交还给 dsh 自己的界面
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
const CONVERSATION_JSON = join(DIR, 'conversation.json')
const USAGE_JSON = join(DIR, 'usage.json')

const HEARTBEAT_FRESH_MS = 15000
const DEFAULT_TIMEOUT_MS = 120000
// 「记录」窗口不必保存全部历史：只要够接上最近的话题即可，避免文件无限长。
const MAX_CONVERSATION = 300
const MAX_TEXT = 8000

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

/** 从 message/content 结构里取纯文本（user 与 assistant 事件共用）。 */
function textFromMessage(message) {
  if (message === null || typeof message !== 'object') return ''
  const blockToText = (block) => {
    if (block === null || typeof block !== 'object') return ''
    if (block.type === 'text' && typeof block.text === 'string') return block.text
    if (block.type === undefined && typeof block.text === 'string') return block.text
    return ''
  }
  if (Array.isArray(message.content)) {
    return message.content.map(blockToText).filter((t) => t !== '').join('\n').trim()
  }
  if (typeof message.text === 'string') return message.text.trim()
  return ''
}

/** 系统注入的运行时上下文不是用户说的话，别写进「记录」。 */
function isInjectedText(text) {
  const t = text.trim()
  return t.startsWith('Current runtime context')
    || t.includes('This snapshot supersedes earlier runtime-context snapshots')
    || t.startsWith('<system-reminder>')
    || t.startsWith('[dsh-cost-meter]')
}

/** 子代理会话不写入桌宠：否则主对话里会混进一堆子任务正文。 */
function isSubagentSession(session) {
  const h = session?.header ?? {}
  const parent = h.parentSessionId ?? h.parentId ?? session?.parentSessionId ?? session?.parentId
  return parent !== undefined && parent !== null && parent !== ''
}

/** 事件里的正文可能挂在 data.message / data.content / data.text 上，逐个试。 */
function eventText(data) {
  const candidates = [data?.message, data?.content, data?.text, data?.message?.message]
  for (const c of candidates) {
    if (Array.isArray(c)) {
      const t = c.map((b) => (b && typeof b === 'object' && typeof b.text === 'string' ? b.text : '')).join('\n').trim()
      if (t !== '') return t
      continue
    }
    if (typeof c === 'string' && c.trim() !== '') return c.trim()
    const t = textFromMessage(c)
    if (t !== '') return t
  }
  return ''
}

/** 从 turn/end 的 data 里尽量捞出 token 用量（不同 dsh 版本字段不一，能取多少取多少）。 */
function usageFromTurnEnd(data) {
  const sources = [data?.usage, data?.tokenUsage, data?.tokens, data?.message?.usage, data]
  for (const src of sources) {
    if (src === null || typeof src !== 'object') continue
    const pick = (...keys) => {
      for (const k of keys) if (typeof src[k] === 'number') return src[k]
      return undefined
    }
    const input = pick('inputTokens', 'input_tokens', 'promptTokens', 'prompt_tokens')
    const output = pick('outputTokens', 'output_tokens', 'completionTokens', 'completion_tokens')
    const cacheRead = pick('cacheReadTokens', 'cache_read_tokens', 'cachedTokens', 'cached_tokens')
    const total = pick('totalTokens', 'total_tokens')
    if (input !== undefined || output !== undefined || total !== undefined) {
      return { input, output, cacheRead, total }
    }
  }
  return null
}

class Bridge {
  constructor(config = {}) {
    this.config = config
    this.status = 'idle'
    this.lastReply = ''
    this.lastTool = ''
    this.sessionId = ''
    this.pendingId = null
    this.conversation = []
    this.timeoutMs = Number.isFinite(config.approvalTimeoutMs) && config.approvalTimeoutMs > 0
      ? config.approvalTimeoutMs
      : DEFAULT_TIMEOUT_MS
  }

  async init() {
    try {
      await mkdir(DIR, { recursive: true })
      await tryUnlink(APPROVAL_JSON)
      await tryUnlink(APPROVAL_REPLY)
      const kept = await readJson(CONVERSATION_JSON)
      if (Array.isArray(kept)) this.conversation = kept.slice(-MAX_CONVERSATION)
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

  /** 追加一条对话并落盘；桌宠「记录」窗口读这个文件。 */
  async appendConversation(role, text) {
    const t = text.trim()
    if (t === '') return
    if (role === 'user' && isInjectedText(t)) return
    const last = this.conversation[this.conversation.length - 1]
    // assistant/message 有时按流式片段多次触发，同角色重复文本合并，避免刷屏。
    if (last !== undefined && last.role === role && last.text === t) return
    this.conversation.push({ t: Date.now() / 1000, role, text: t.slice(0, MAX_TEXT) })
    if (this.conversation.length > MAX_CONVERSATION) {
      this.conversation = this.conversation.slice(-MAX_CONVERSATION)
    }
    try {
      await atomicWrite(CONVERSATION_JSON, JSON.stringify(this.conversation))
    } catch { /* ignore */ }
  }

  async onSessionEvent(session, event) {
    const type = event?.type
    if (typeof type !== 'string') return
    const data = event.data !== null && typeof event.data === 'object' ? event.data : {}
    // 子代理的事件一律忽略：状态和「记录」只反映与用户对话的那个会话
    if (isSubagentSession(session)) return
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
      case 'user/message': {
        const text = eventText(data)
        if (text !== '') await this.appendConversation('user', text)
        break
      }
      case 'assistant/message': {
        const text = eventText(data) || textFromMessage(data.message)
        if (text !== '') {
          this.lastReply = text
          try { await atomicWrite(REPLY_TXT, text) } catch { /* ignore */ }
          await this.appendConversation('assistant', text)
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
        const usage = usageFromTurnEnd(data)
        if (usage !== null) {
          try {
            await atomicWrite(USAGE_JSON, JSON.stringify({
              ...usage,
              sessionId: this.sessionId,
              updatedAt: Date.now(),
            }))
          } catch { /* ignore */ }
        }
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
