// 洛琪希桌宠 Roxy Desktop Pet — v3
// 独立小应用（不依赖、不修改 ChatGPT/Codex 应用）。
//
// 交互：
//   1. 鼠标悬停她身上 → 跳跃反应（循环）；移开后 → "跟随窗口"10 秒（16 方向转头看鼠标）
//   2. 按住拖动 → 按方向播放 左/右奔跑；右键菜单
//   3. 说话（气泡）：打招呼 / 随机闲聊 / 整点报时 / 电池提醒 / Claude Code 事件
//   4. 接入 Claude Code（~/.roxy-pet/state）：干活=工作跑动；完工=挥手+台词；等待确认=提醒
//   5. 点选"让洛琪希想句话"→ 调用大模型现场生成她的台词（默认本地台词库，零 token 消耗）
//
// 人设：洛琪希·米格路迪亚（《无职转生》），水圣级魔术师、家庭教师
//   台词风格依据小说原文采样：认真、礼貌、教学式鼓励、偶尔小害羞；习惯点头/苦笑/脸红
//
// 素材：官方 pets v2 图集 1536×2288（8 列 × 11 行，单格 192×208）
//   行 0 idle / 行 1 running-right / 行 2 running-left / 行 3 waving / 行 4 jumping
//   行 5 failed / 行 6 waiting / 行 7 running(工作) / 行 8 review
//   行 9-10：16 个视线方向帧（0°=正上，顺时针每 22.5° 一档）

import Cocoa
import Darwin
import QuartzCore
import WebKit

// ============ 可调参数 ============
let WINDOW_SCALE: CGFloat = 0.75          // 显示缩放（0.75 → 144×156 点）
let LOOK_WINDOW_SECONDS: Double = 5       // 悬停触发后，"跟随"持续的秒数
let HEAD_CENTER_X_RATIO: CGFloat = 0.5    // "头中心"横向位置（算方向用）
let HEAD_CENTER_Y_RATIO: CGFloat = 0.72   // "头中心"纵向位置（0=底，1=顶）
let CLICK_MAX_MOVE: CGFloat = 4.0         // 按下-抬起位移小于此值视为"点击"
let TICK_FPS: Double = 60.0               // 主循环频率
let STATE_POLL_INTERVAL: Double = 0.25    // Claude Code 状态文件轮询间隔（秒）
let WORK_TIMEOUT_SECONDS: Double = 1200   // working 状态超过 20 分钟无更新则忽略
let WAVE_REPEAT = 2                       // 挥手播放遍数

// 说话与提醒
let GREET_DELAY: Double = 6.0             // 启动后多少秒打招呼
let CHAT_INTERVAL_MIN: Double = 360       // 随机闲聊间隔下限（秒）
let CHAT_INTERVAL_MAX: Double = 720       // 随机闲聊间隔上限（秒）
let CHIME_QUIET_FROM = 23                 // 整点报时静音时段（含）
let CHIME_QUIET_TO = 7                    // 整点报时静音时段（不含）

// ============ 图集规格（官方 pets v2）============
let CELL_W = 192
let CELL_H = 208
let COLS = 8
let ROWS = 11

func dirToRowCol(_ dir: Int) -> (row: Int, col: Int) { (9 + dir / 8, dir % 8) }
func randomOf(_ arr: [String]) -> String { arr.randomElement() ?? "" }

// ============ 台词库（洛琪希口吻：认真、礼貌、教学式鼓励）============
var GREETINGS = [
    "我来了，法杖也放好了。今天也请多指教哦。",
    "这里就是{称呼}的桌面吗？嗯……是个让人安心的好地方呢，像旅途里歇脚的小屋。",
    "呼……收拾好法杖就过来了。今天也一起加油吧。",
    "从另一个世界来到这里的洛琪希·米格路迪亚，前来报到。……嗯，开玩笑的。请多指教哦。",
]
// CHAT_LINES 内容已经过世界观优化，迁移至 speech.swift 的 CHAT_EXTRA
var CHAT_LINES: [String] = []
var BATTERY_20 = [
    "电量只剩不到两成了……唔，我的魔术帮不上忙，请记得接上电源哦。",
    "唔……电量有点危险了呢，就像咏唱到一半魔力不足那样。记得充电哦。",
]
var BATTERY_10 = [
    "危险！这块小魔道具快撑不住了，请马上接上电源！",
    "电量告急！再不接上电源，它就要沉睡了……拜托快去接吧！",
]
var BATTERY_FULL = [
    "电充好啦——像魔石重新注满那样，状态绝佳！",
    "能量恢复完毕。托您的福，它又能陪我很久了呢。",
]
var DONE_LINES = [
    "完成了哦。就像委托达成那样，干脆利落呢。",
    "工作完成，辛苦了。像冒险归来的夜晚，值得一杯热茶呢。",
    "呼——做完了。要像验收委托那样，检查一下结果吗？",
]
var NOTICE_LINES = [
    "好像有份委托单需要您确认一下呢。",
    "那个……好像有新的念话传过来了，在等您哦。",
]
var AI_THINKING = [
    "嗯……让我翻开魔导书想一下。",
    "稍等，我占卜——不对，是思考一下。",
]
var AI_FAIL = [
    "呜……魔术发动失败了。待会儿再试一次吧。",
    "唔，没能连上那边的世界……再试一次好吗？",
]

// 整点报时（按时间段）
func hourlyLine(_ hour24: Int) -> String {
    let h12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    switch hour24 {
    case 7...11:  return "上午\(h12)点了哦。今天也慢慢来吧。"
    case 12:      return "中午十二点啦。有好好吃午饭吗？"
    case 13...17: return "已经下午\(h12)点了哦。喝杯茶歇口气也不错呢。"
    case 18...22: return "晚上\(h12)点了呢。今天也辛苦您了。"
    default:      return "\(h12)点了哦。"
    }
}

// ============ 气泡视图 ============
final class BubbleView: NSView {
    weak var controller: PetController?
    var text: String = "" {
        didSet { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        controller?.bubbleClicked()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11)
        NSColor(calibratedWhite: 0.08, alpha: 0.82).setFill()
        path.fill()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.96),
            .paragraphStyle: para,
        ]
        (text as NSString).draw(in: bounds.insetBy(dx: 12, dy: 9), withAttributes: attrs)
    }
}

func bubbleSize(for text: String) -> NSSize {
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .paragraphStyle: para,
    ]
    let maxTextW: CGFloat = 240
    let r = (text as NSString).boundingRect(with: NSSize(width: maxTextW, height: 600),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                            attributes: attrs)
    return NSSize(width: ceil(r.width) + 24, height: ceil(r.height) + 18)
}

// ============ 视图：绘制 + 拖拽 + 点击穿透 ============
final class PetView: NSView {
    weak var controller: PetController?
    private var dragStart: NSPoint = .zero
    private var origOrigin: NSPoint = .zero
    private var dragged = false

    override func draw(_ dirtyRect: NSRect) {
        if let img = controller?.currentImage {
            img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }

    // 透明像素处让点击穿透到下层窗口（用稳定的站姿轮廓判定）
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let c = controller, let sv = superview else { return super.hitTest(point) }
        let p = convert(point, from: sv)
        guard bounds.contains(p) else { return nil }
        guard c.isOpaquePixel(viewPoint: p) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        origOrigin = window?.frame.origin ?? .zero
        dragged = false
        controller?.dragStarted(atMouseX: dragStart.x, atMouseY: dragStart.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let loc = NSEvent.mouseLocation
        if hypot(loc.x - dragStart.x, loc.y - dragStart.y) > CLICK_MAX_MOVE { dragged = true }
        win.setFrameOrigin(NSPoint(x: origOrigin.x + (loc.x - dragStart.x),
                                   y: origOrigin.y + (loc.y - dragStart.y)))
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { controller?.petClicked() }
        controller?.dragEnded()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(with: event)
    }
}

// ============ 控制器 ============
final class PetController: NSObject, NSApplicationDelegate {
    private var characters = PetCharacter.loadCatalog()
    private var character = PetCharacter.roxy
    private var characterName: String { character.name }

    // 单实例锁：flock 持有到进程退出，避免仓库版与 /Applications 版各跑一只。
    private var instanceLockFD: Int32 = -1

    private func acquireSingleInstanceLock() -> Bool {
        let dir = NSHomeDirectory() + "/.roxy-pet"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir + "/roxy.lock", O_CREAT | O_RDWR, 0o644)
        if fd < 0 { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    private func lines(_ key: String, _ fallback: [String]) -> [String] {
        character.lines(key, roxy: fallback)
    }

    var window: NSWindow?
    var petView: PetView?

    private var frames: [[NSImage]] = []      // [row][col]
    private var masks: [[[UInt8]]] = []       // [row][col][pixel] alpha
    private var hoverMask: [UInt8] = []       // 交互判定用"站姿轮廓"（行 0 全部帧并集）
    // Optional costume-specific clips leave the six existing base atlases untouched.
    private struct ExtraActionDescription: Decodable {
        let id: String
        let title: String
        let row: Int
        let frameCount: Int
        let frameDuration: Double
    }
    private struct ExtraActionManifest: Decodable {
        let version: Int
        let columns: Int
        let rows: Int
        let cellWidth: Int
        let cellHeight: Int
        let actions: [ExtraActionDescription]
    }
    private struct ExtraClip {
        let description: ExtraActionDescription
        let frames: [NSImage]
        var sequence: [(Int, Double)] { frames.indices.map { ($0, description.frameDuration) } }
    }
    private struct ExtraBehavior {
        let idle: String
        let salute: String
        let work: String
        let done: String
    }
    private var extraBehavior: ExtraBehavior? {
        switch character.id {
        case "roxy":
            return ExtraBehavior(idle: "staff-idle", salute: "staff-salute", work: "staff-channel", done: "water-cast")
        case "roxy-nohat", "sylphie-adult", "sylphie-chibi":
            return ExtraBehavior(idle: "daily-rest", salute: "daily-greet", work: "daily-focus", done: "daily-greet")
        case "eris-short", "eris-long":
            return ExtraBehavior(idle: "sword-idle", salute: "sword-salute", work: "sword-practice", done: "sword-salute")
        default: return nil
        }
    }
    private var deterministicActionChecks = false
    private var lastContextAction: [String: String] = [:]
    private var nextIdleDelay = Double.random(in: 60...100)
    private var lastStormAt: CFTimeInterval?

    private static func variedChoice(_ candidates: [String], previous: String?, entropy: UInt) -> String {
        precondition(!candidates.isEmpty)
        let fresh = candidates.count > 1 ? candidates.filter { $0 != previous } : candidates
        let choices = fresh.isEmpty ? candidates : fresh
        return choices[Int(entropy % UInt(choices.count))]
    }

    private func contextAction(_ primary: String, alternatives: [String], context: String) -> String {
        if deterministicActionChecks { return primary }
        var choices: [String] = []
        for id in [primary] + alternatives where (extraClips[id] != nil || id == "wave") && !choices.contains(id) {
            choices.append(id)
        }
        guard !choices.isEmpty else { return primary }
        let key = character.id + ":" + context
        let choice = Self.variedChoice(choices, previous: lastContextAction[key], entropy: UInt.random(in: 0...UInt.max))
        lastContextAction[key] = choice
        return choice
    }

    private func completionExtraID(workDuration: Double? = nil) -> String? {
        if character.id == "roxy", let seconds = workDuration, seconds.isFinite,
           seconds >= CompletionWorkTiming.signatureThreshold, extraClips["cumulonimbus"] != nil {
            let now = CACurrentMediaTime()
            if deterministicActionChecks || ((lastStormAt == nil || now - lastStormAt! >= 180) && Int.random(in: 0..<3) == 0) {
                lastStormAt = now
                return "cumulonimbus"
            }
        }
        guard let behavior = extraBehavior, extraClips[behavior.done] != nil else { return nil }
        return contextAction(behavior.done, alternatives: [behavior.salute], context: "success")
    }
    /// Only continuous work actually observed in this costume counts toward a large completion spell.
    /// Notice, missing/stale state, cancellation, or switching costume starts a fresh interval.
    private struct CompletionWorkTiming {
        static let signatureThreshold = 120.0
        private(set) var startedAtBySource: [String: CFTimeInterval] = [:]

        mutating func update(workingSources: Set<String>, at now: CFTimeInterval) {
            guard now.isFinite else { reset(); return }
            startedAtBySource = startedAtBySource.filter { workingSources.contains($0.key) && $0.value <= now }
            for source in workingSources where startedAtBySource[source] == nil {
                startedAtBySource[source] = now
            }
        }

        func duration(for source: String, at now: CFTimeInterval) -> Double? {
            guard let started = startedAtBySource[source], now.isFinite, now >= started else { return nil }
            return now - started
        }

        mutating func reset() { startedAtBySource.removeAll() }
    }
    private struct DirectWorkTiming {
        let startedAt: CFTimeInterval
        let costumeID: String

        func duration(for costume: String, at now: CFTimeInterval, successful: Bool) -> Double? {
            guard successful, costume == costumeID, now.isFinite, now >= startedAt else { return nil }
            return now - startedAt
        }
    }
    private var completionWorkTiming = CompletionWorkTiming()
    private var directWorkTiming: DirectWorkTiming?
    private enum WorkspaceActivitySignal {
        case willSleep, screensDidSleep, sessionDidResignActive
        case didWake, screensDidWake, sessionDidBecomeActive
    }
    private enum WorkspacePause: Hashable { case system, screens, session }
    private enum AmbientReason { case idle, work, returnSalute }

    /// Aggregate input-idle seconds only; no key contents, event taps, or window inspection.
    private struct SystemActivityState {
        var idleSeconds: Double?
        var lastSampleAt: TimeInterval?
        var peakIdleSeconds = 0.0
        var idlePosePlayed = false
        var pendingReturnSalute = false
        var lastReturnSaluteAt: TimeInterval?
        var pauses = Set<WorkspacePause>()
        var awaitingWakeInput = false
        var wakeInputConsumed = false
        var isPaused: Bool { !pauses.isEmpty }
        var canAnimateAutomatically: Bool { !isPaused && !awaitingWakeInput && idleSeconds != nil }

        mutating func receive(_ signal: WorkspaceActivitySignal) {
            let wasPaused = isPaused
            switch signal {
            case .willSleep: pauses.insert(.system)
            case .screensDidSleep: pauses.insert(.screens)
            case .sessionDidResignActive: pauses.insert(.session)
            case .didWake: pauses.remove(.system)
            case .screensDidWake: pauses.remove(.screens)
            case .sessionDidBecomeActive: pauses.remove(.session)
            }
            switch signal {
            case .willSleep, .screensDidSleep, .sessionDidResignActive:
                awaitingWakeInput = true
                wakeInputConsumed = false
                pendingReturnSalute = false
            case .didWake, .screensDidWake, .sessionDidBecomeActive:
                if !wakeInputConsumed { awaitingWakeInput = true }
            }
            if wasPaused && !isPaused && awaitingWakeInput {
                // A wake key may arrive before the final workspace notification.
                idleSeconds = nil
                lastSampleAt = nil
            }
        }

        @discardableResult mutating func sample(idleSeconds seconds: Double, at now: TimeInterval) -> Bool {
            guard seconds.isFinite, seconds >= 0, now.isFinite else {
                idleSeconds = nil; lastSampleAt = nil; peakIdleSeconds = 0
                return false
            }
            let elapsed = lastSampleAt.map { max(0, now - $0) } ?? 0
            let inputObserved = seconds < 3 && (idleSeconds == nil || seconds + 0.25 < idleSeconds! + elapsed)
            let returnedAfterAbsence = peakIdleSeconds >= 180
            idleSeconds = seconds
            lastSampleAt = now
            if isPaused {
                peakIdleSeconds = max(peakIdleSeconds, seconds)
                return inputObserved
            }
            if inputObserved {
                if returnedAfterAbsence || awaitingWakeInput {
                    if lastReturnSaluteAt == nil || now - lastReturnSaluteAt! >= 120 { pendingReturnSalute = true }
                }
                idlePosePlayed = false
                peakIdleSeconds = seconds
                if awaitingWakeInput {
                    awaitingWakeInput = false
                    wakeInputConsumed = true
                }
            } else {
                peakIdleSeconds = max(peakIdleSeconds, seconds)
            }
            return inputObserved
        }

        mutating func takeReturnSalute(at now: TimeInterval) -> Bool {
            guard pendingReturnSalute else { return false }
            pendingReturnSalute = false
            guard lastReturnSaluteAt == nil || now - lastReturnSaluteAt! >= 120 else { return false }
            lastReturnSaluteAt = now
            return true
        }

        mutating func acknowledgeReturn(at now: TimeInterval) {
            pendingReturnSalute = false
            lastReturnSaluteAt = now
        }

        mutating func resetForCostumeChange() {
            idleSeconds = nil; lastSampleAt = nil; peakIdleSeconds = 0
            idlePosePlayed = false; pendingReturnSalute = false
            awaitingWakeInput = isPaused
            wakeInputConsumed = !isPaused
        }
    }
    private var extraClips: [String: ExtraClip] = [:]
    private var nextExtraWorkActionAt: CFTimeInterval = 0
    private var systemActivity = SystemActivityState()
    private var lastSystemActivityPollAt: CFTimeInterval = 0
    private var observingWorkspaceActivity = false
    private var ambientOnce = false
    private var ambientReason: AmbientReason?
    private var chainedExtraKind: String?
    private var timer: Timer?

    private(set) var currentImage: NSImage?
    private var currentRow = -1
    private var currentCol = -1
    private var currentSheetKey = "base"
    private var lastTick: CFTimeInterval = 0
    private var startTime: CFTimeInterval = 0

    // 动画序列：[(列, 每帧秒数)]
    private let IDLE_SEQ: [(Int, Double)] = [(0, 1.0)]   // 待机＝静帧；第 1~5 列是一次完整眨眼弧的分解动作，由拟真调度器整弧播放
    private let BLINK_SEQ: [(Int, Double)] = [(1, 0.06), (2, 0.05), (3, 0.10), (4, 0.05), (5, 0.06)]  // 眨眼弧：一睁→半闭→闭→半睁→睁（约 0.32 秒）
    private let JUMP_SEQ: [(Int, Double)] = [(0, 0.14), (1, 0.14), (2, 0.14), (3, 0.14), (4, 0.28)]
    private let WAVE_SEQ: [(Int, Double)] = [(0, 0.14), (1, 0.14), (2, 0.14), (3, 0.28)]
    private let RUN_SEQ:  [(Int, Double)] = [(0, 0.12), (1, 0.12), (2, 0.12), (3, 0.12), (4, 0.12), (5, 0.12), (6, 0.12), (7, 0.22)]
    private let WORK_SEQ: [(Int, Double)] = [(0, 0.12), (1, 0.12), (2, 0.12), (3, 0.12), (4, 0.12), (5, 0.22), (5, 1.00)]  // 末尾定格 1 秒：工作循环做完停一拍，避免"低头"动作过密

    // 动画播放状态
    private var animKey = ""
    private var animElapsed = 0.0
    private var onceKind = ""                 // Base reactions or a validated optional clip ID.
    private var onceRepeatsLeft = 0
    private var pendingOnce = ""
    private var pendingOnceRepeats: Int? = nil

    // 交互状态
    private var wasHovering = false
    private var nextTouchIsJump = true             // 触碰反应交替开关：true=跳，false=挥手
    private var lastClickAction: String? = nil
    private var clickActionBag: [String] = []
    private var queuedClickKind: String?
    private var lookUntil = 0.0
    private var lastLookDir = -1
    private var dragging = false
    private var dragMoved = false                 // 位移超过点击阈值才算"真的在拖"
    private var dragRight = true
    private var dragPrevX: CGFloat = 0
    private var dragStartPoint = NSPoint.zero

    // Claude Code 状态
    private var workState = "idle"
    private var lastOnceTS = 0.0
    private var statePollAcc = 0.0

    // DeepSeek Harness 桥（dsh-plugin-roxy）
    private var dshApprovalAcc = 0.0
    private var lastDshApprovalId = ""
    private var dshHeartbeatAcc = 0.0
    /// dsh 是否已接入（启动时检测到 dsh 命令）
    private static func isDshConnected() -> Bool { harnessPaths["dsh"] != nil }
    /// 最近一次余额（总额）与展示文案；实时显示用
    private var dshBalanceTotal: Double?
    private var dshBalanceText = ""
    private var dshBalanceAcc = 0.0
    private var dshBalanceInFlight = false
    /// 对话同步：DSH 双向对话（user/message + assistant/message）
    private var dshHistory: [TaskRecord] = []
    private var dshHistorySig = ""
    private var dshHistoryAcc = 0.0
    /// 未连接时的定期自动探测（每 5 分钟）
    private var harnessDetectAcc = 0.0

    // 气泡
    private var bubbleWindow: NSWindow?
    private var bubbleView: BubbleView?
    private var bubbleHideAt: CFTimeInterval = 0
    private var bubbleVisible = false
    private var bubbleCopyText = ""
    private var bubbleResumeSid: String?
    private var bubbleResumeTty: String?
    private var bubbleResumeTerm: String?

    // 行为调度
    private var greeted = false
    private var lastChimeHour = -1
    private var nextChatAt: CFTimeInterval = 0
    private var batteryAcc: Double = 0
    private var battLevel = 100
    private var battCharging = true
    private var battWarnStep = 0              // 0=未警告, 1=已警告20%, 2=已警告10%
    private var battFullWarned = false
    private var aiBusy = false {
        didSet { statusItem?.menu = makeMenu(forStatusBar: true) }
    }
    private var petHidden = false
    private var ownerTitle = UserDefaults.standard.string(forKey: "roxyOwnerTitle") ?? ""
    private var ocWatchRunning = false
    // 拟真眨眼调度（仅待机时）：随机间隔 + 偶发连眨
    private var blinkAt: CFTimeInterval = 0
    private var blinkUntil: CFTimeInterval = 0
    private var blinkDoubleAt: CFTimeInterval = 0
    private var glanceAt: CFTimeInterval = 0       // 下一次"侧头瞥一眼"的时间
    private var glanceUntil: CFTimeInterval = 0     // 本次瞥视结束时间
    private var glanceDir: Int = 4                  // 瞥视方向（16 向：4=右，12=左）
    private var statusItem: NSStatusItem?
    private var statusVisibilityItem: NSMenuItem?

    // ---------- 吩咐记录（持久保存，可随时查看）----------
    private struct TaskRecord: Codable {
        let t: Double
        let role: String   // "user" / "roxy"
        let text: String
        var characterID: String? = nil
        var characterName: String? = nil
    }
    private var taskHistory: [TaskRecord] = []
    private var historyWindow: NSWindow?
    private var historyWeb: WKWebView?

    private static func historyFilePath() -> String {
        let dir = NSHomeDirectory() + "/.roxy-pet"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/task-history.json"
    }
    private func loadTaskHistory() {
        if let data = FileManager.default.contents(atPath: PetController.historyFilePath()),
           let arr = try? JSONDecoder().decode([TaskRecord].self, from: data) {
            taskHistory = arr
        }
        loadDshHistory()
        // 防断裂：上次若有一条"用户消息"没等到回答（App 中途退出/重启），补一条说明
        if let last = taskHistory.last, last.role == "user" {
            taskHistory.append(TaskRecord(t: Date().timeIntervalSince1970, role: "roxy",
                                          text: "（上次的请求在途中被打断了，可以再发一次。）",
                                          characterID: last.characterID, characterName: last.characterName))
            saveTaskHistory()
        }
    }
    /// 对话同步：读回 dsh 桥插件写的双向对话（user/message + assistant/message）。
    /// 只用于「记录」窗口展示，不写回 task-history.json（各存各的，互不覆盖）。
    private func loadDshHistory() {
        let d = UserDefaults.standard
        if d.object(forKey: "roxyDshConversation") != nil, !d.bool(forKey: "roxyDshConversation") {
            if !dshHistory.isEmpty { dshHistory = [] }
            dshHistorySig = "off"
            return
        }
        let path = NSHomeDirectory() + "/.roxy-pet/dsh/conversation.json"
        guard let data = FileManager.default.contents(atPath: path),
              let arr = try? JSONDecoder().decode([TaskRecord].self, from: data) else {
            if !dshHistory.isEmpty { dshHistory = [] }
            return
        }
        // 系统注入的运行时上下文每轮都会作为 user 消息出现，展示时丢掉
        let noise = ["Current runtime context",
                     "This snapshot supersedes earlier runtime-context snapshots",
                     "<system-reminder>",
                     "[dsh-cost-meter]"]
        dshHistory = arr.filter { rec in
            !noise.contains { rec.text.hasPrefix($0) || rec.text.contains($0) }
        }.map { rec in
            if rec.role == "user" {
                return TaskRecord(t: rec.t, role: "user", text: rec.text, characterID: nil, characterName: nil)
            }
            return TaskRecord(t: rec.t, role: "roxy", text: rec.text, characterID: nil, characterName: "Harness")
        }
        dshHistorySig = "\(dshHistory.count)-\(dshHistory.last?.t ?? 0)"
    }
    private func saveTaskHistory() {
        if taskHistory.count > 500 { taskHistory.removeFirst(taskHistory.count - 500) }
        if let data = try? JSONEncoder().encode(taskHistory) {
            try? data.write(to: URL(fileURLWithPath: PetController.historyFilePath()))
        }
    }
    private func appendHistory(role: String, text: String) {
        taskHistory.append(TaskRecord(t: Date().timeIntervalSince1970, role: role, text: text, characterID: character.characterID, characterName: character.name))
        saveTaskHistory()
        refreshHistoryWindow()
    }
    private func historyFullText() -> String {
        guard !taskHistory.isEmpty else { return "（还没有记录哦。\n\n在菜单里选「\(character.actionTitle)」，把任务交给我吧。）" }
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        var parts: [String] = []
        for r in taskHistory.reversed() {
            let who = (r.role == "user") ? "你" : (r.characterName ?? "洛琪希")
            parts.append("▸ " + df.string(from: Date(timeIntervalSince1970: r.t)) + "　" + who + "：\n" + r.text)
        }
        return parts.joined(separator: "\n\n────────────────────\n\n")
    }
    private func refreshHistoryWindow() {
        // 重新载入渲染好的聊天页（不检查窗口可见性，首次打开前也要写好）
        historyWeb?.loadHTMLString(historyHTML(), baseURL: nil)
    }

    private func htmlEscape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }

    /// 迷你 Markdown → HTML（标题 / 加粗 / 行内代码 / 代码块 / 列表 / 引用 / 表格 / 分隔线 / 链接）
    private func mdToHTML(_ md: String) -> String {
        func inline(_ s: String) -> String {
            var t = htmlEscape(s)
            t = t.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
            return t
        }
        var out: [String] = []
        var inCode = false
        var listKind = ""
        var inTable = false
        func closeList() { if !listKind.isEmpty { out.append("</\(listKind)>"); listKind = "" } }
        func closeTable() { if inTable { out.append("</table>"); inTable = false } }
        for rawLine in md.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                closeList(); closeTable()
                if inCode { out.append("</code></pre>"); inCode = false }
                else { out.append("<pre><code>"); inCode = true }
                continue
            }
            if inCode { out.append(htmlEscape(rawLine)); continue }
            if trimmed.isEmpty { closeList(); closeTable(); continue }
            if trimmed.hasPrefix("#") {
                closeList(); closeTable()
                let level = min(max(trimmed.prefix(while: { $0 == "#" }).count, 1), 4)
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                out.append("<h\(level)>\(inline(text))</h\(level)>")
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                closeList(); closeTable(); out.append("<hr>"); continue
            }
            if trimmed.hasPrefix(">") {
                closeList(); closeTable()
                let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                out.append("<blockquote>\(inline(text))</blockquote>")
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                closeTable()
                if listKind != "ul" { closeList(); out.append("<ul>"); listKind = "ul" }
                out.append("<li>\(inline(String(trimmed.dropFirst(2))))</li>")
                continue
            }
            if let r = trimmed.range(of: "^[0-9]{1,2}\\. ", options: .regularExpression) {
                closeTable()
                if listKind != "ol" { closeList(); out.append("<ol>"); listKind = "ol" }
                out.append("<li>\(inline(String(trimmed[r.upperBound...])))</li>")
                continue
            }
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                closeList()
                let cells = String(trimmed.dropFirst().dropLast()).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy({ c in c == "-" || c == ":" || c == " " }) }) { continue }
                if !inTable { out.append("<table>"); inTable = true }
                out.append("<tr>" + cells.map { "<td>\(inline($0))</td>" }.joined() + "</tr>")
                continue
            }
            closeList(); closeTable()
            out.append("<p>\(inline(trimmed))</p>")
        }
        if inCode { out.append("</code></pre>") }
        closeList(); closeTable()
        return out.joined(separator: "\n")
    }

    private func historyHTML() -> String {
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        var rows = ""
        let merged = (taskHistory + dshHistory).sorted { $0.t < $1.t }
        if merged.isEmpty {
            rows = "<div class='empty'>还没有记录哦～<br>在菜单里选「\(character.actionTitle)」，把任务交给我吧。</div>"
        } else {
            for r in merged {
                let isUser = (r.role == "user")
                let who = htmlEscape(isUser ? "你" : (r.characterName ?? "洛琪希"))
                let cls = isUser ? "me" : "roxy"
                let time = df.string(from: Date(timeIntervalSince1970: r.t))
                let body = isUser ? "<p>\(htmlEscape(r.text))</p>" : mdToHTML(r.text)
                rows += "<div class='row \(cls)'><div class='bubble'><div class='meta'>\(who) · \(time)</div><div class='body'>\(body)</div></div></div>\n"
            }
        }
        let css = """
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 14px 16px 20px; font: 13px/1.65 -apple-system, 'PingFang SC', 'Helvetica Neue', sans-serif; }
        .row { display: flex; margin: 10px 0; }
        .row.me { justify-content: flex-end; }
        .bubble { max-width: 84%; border-radius: 13px; padding: 8px 13px; word-break: break-word; }
        .row.me .bubble { background: #3f7fd4; color: #fff; }
        .row.me .meta { color: rgba(255,255,255,.75); }
        .row.roxy .bubble { background: rgba(127,127,127,.16); }
        .meta { font-size: 11px; opacity: .72; margin-bottom: 4px; }
        .body p { margin: 4px 0; }
        .body h1, .body h2 { font-size: 16px; margin: 8px 0 5px; }
        .body h3, .body h4 { font-size: 14px; margin: 7px 0 4px; }
        code { font-family: ui-monospace, Menlo, monospace; font-size: 12px; background: rgba(127,127,127,.20); padding: 1px 5px; border-radius: 5px; }
        .row.me code { background: rgba(255,255,255,.22); }
        pre { background: rgba(127,127,127,.14); padding: 8px 10px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: 12px; }
        ul, ol { margin: 4px 0; padding-left: 20px; }
        li { margin: 2px 0; }
        blockquote { margin: 6px 0; padding: 2px 10px; border-left: 3px solid rgba(127,127,127,.5); }
        blockquote p { margin: 2px 0; }
        table { border-collapse: collapse; margin: 6px 0; }
        td, th { border: 1px solid rgba(127,127,127,.35); padding: 3px 8px; font-size: 12px; }
        hr { border: none; border-top: 1px solid rgba(127,127,127,.3); margin: 10px 0; }
        a { color: inherit; }
        .empty { text-align: center; opacity: .6; padding: 48px 0; }
        """
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>\(css)</style></head>
        <body>
        \(rows)
        <script>setTimeout(function(){ window.scrollTo(0, document.body.scrollHeight); }, 80);</script>
        </body></html>
        """
    }
    @objc private func showTaskHistory() {
        if historyWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "\(characterName) · \(character.historyTitle)"
            w.isReleasedWhenClosed = false
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 540))
            web.autoresizingMask = [.width, .height]
            w.contentView = web
            w.center()
            historyWindow = w
            historyWeb = web
        }
        loadDshHistory()
        refreshHistoryWindow()
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private var lastSpokenLine = ""

    // 情绪与情境（本地逻辑，零 token）
    private enum Mood { case calm, shy, lonely }
    private var mood: Mood = .calm
    private var moodUntil: CFTimeInterval = 0
    private var petStreak = 0
    private var lastPetAt: CFTimeInterval = 0
    private var lastInteractAt: CFTimeInterval = 0

    // 方向语料（转头跟随时按方位说话）
    private var lastDirSpokeAt: CFTimeInterval = 0
    private var lastDirSpokenSlot = -1

    // ---------- 启动 ----------
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 单实例锁：仓库版与 /Applications 版同时打开时会各放一只，必须只留一个。
        guard acquireSingleInstanceLock() else {
            NSLog("Roxy: another instance is already running; exiting")
            NSApp.terminate(nil)
            return
        }
        // 每次启动都从洛琪希开始；「角色」菜单可在本次运行里随时切换
        character = characters.first(where: { $0.isRoxy }) ?? characters[0]
        if !loadAtlas() { character = characters[0] }
        guard !frames.isEmpty || loadAtlas() else {
            NSLog("Roxy: failed to load spritesheet")
            NSApp.terminate(nil)
            return
        }
        setupWindow()
        loadSpeechExtras()
        loadTaskHistory()
        setupStatusItem()
        PetController.detectHarnesses()
        if UserDefaults.standard.object(forKey: "roxyOwnerTitle") == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.promptForTitle(firstRun: true)
            }
        }
        startTime = CACurrentMediaTime()
        show(row: 0, col: 0)
        observeWorkspaceActivity()
        startTimer()
        // 若因授权流程重启，则自动续跑一次「透视魔法」（有权限直接看，没有则轻声提示，不打扰）
        let rf = NSHomeDirectory() + "/.roxy-pet/peek-retry"
        if FileManager.default.fileExists(atPath: rf) {
            try? FileManager.default.removeItem(atPath: rf)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self else { return }
                if CGPreflightScreenCaptureAccess() {
                    self.lookAtScreen()
                } else {
                    self.speak("唔……还是没有拿到「看屏幕」的权限呢。可以在设置里再确认一下哦。", seconds: 10)
                }
            }
        }
    }

    private func observeWorkspaceActivity() {
        guard !observingWorkspaceActivity else { return }
        observingWorkspaceActivity = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(workspaceActivityChanged(_:)), name: name, object: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate()
    }

    @objc private func workspaceActivityChanged(_ notification: Notification) {
        let signal: WorkspaceActivitySignal
        switch notification.name {
        case NSWorkspace.willSleepNotification: signal = .willSleep
        case NSWorkspace.screensDidSleepNotification: signal = .screensDidSleep
        case NSWorkspace.sessionDidResignActiveNotification: signal = .sessionDidResignActive
        case NSWorkspace.didWakeNotification: signal = .didWake
        case NSWorkspace.screensDidWakeNotification: signal = .screensDidWake
        case NSWorkspace.sessionDidBecomeActiveNotification: signal = .sessionDidBecomeActive
        default: return
        }
        if Thread.isMainThread { receiveWorkspaceActivity(signal) }
        else { DispatchQueue.main.async { [weak self] in self?.receiveWorkspaceActivity(signal) } }
    }

    private func receiveWorkspaceActivity(_ signal: WorkspaceActivitySignal) {
        systemActivity.receive(signal)
        if systemActivity.isPaused || systemActivity.awaitingWakeInput {
            cancelAmbientOnce()
            nextExtraWorkActionAt = 0
        }
    }

    private func pollSystemActivity(now: CFTimeInterval) {
        guard lastSystemActivityPollAt == 0 || now - lastSystemActivityPollAt >= 1 else { return }
        lastSystemActivityPollAt = now
        let anyInputEvent = CGEventType(rawValue: UInt32.max)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
        acceptSystemActivity(idleSeconds: idle, at: Date().timeIntervalSince1970)
    }

    private func acceptSystemActivity(idleSeconds: Double, at now: TimeInterval) {
        let inputObserved = systemActivity.sample(idleSeconds: idleSeconds, at: now)
        if inputObserved && ambientReason != .returnSalute { cancelAmbientOnce() }
    }

    private func loadAtlas() -> Bool {
        guard let url = character.atlasURL,
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }

        // Build locally so a malformed replacement cannot corrupt the current pet.
        var newFrames: [[NSImage]] = []
        var newMasks: [[[UInt8]]] = []
        guard cg.width >= COLS * 32, cg.height >= ROWS * 32,
              abs(Double(cg.width) / Double(cg.height) - Double(COLS * CELL_W) / Double(ROWS * CELL_H)) < 0.02,
              [.premultipliedLast, .premultipliedFirst, .last, .first].contains(cg.alphaInfo)
        else { return false }
        for row in 0..<ROWS {
            var rowFrames: [NSImage] = []
            var rowMasks: [[UInt8]] = []
            for col in 0..<COLS {
                guard let ctx = CGContext(data: nil, width: CELL_W, height: CELL_H,
                                          bitsPerComponent: 8, bytesPerRow: CELL_W * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.translateBy(x: -CGFloat(col * CELL_W), y: -CGFloat((ROWS - 1 - row) * CELL_H))
                ctx.draw(cg, in: CGRect(x: 0, y: 0,
                                        width: CGFloat(COLS * CELL_W),
                                        height: CGFloat(ROWS * CELL_H)))
                // Keep source-resolution pixels for Retina displays. The separate 192x208
                // context below is only for hit testing, never the displayed image.
                let sourceW = CGFloat(cg.width) / CGFloat(COLS)
                let sourceH = CGFloat(cg.height) / CGFloat(ROWS)
                guard let cell = cg.cropping(to: CGRect(x: CGFloat(col) * sourceW,
                                                        y: CGFloat(row) * sourceH,
                                                        width: sourceW, height: sourceH)) else { return false }
                rowFrames.append(NSImage(cgImage: cell, size: NSSize(width: CELL_W, height: CELL_H)))

                let buf = ctx.data!.assumingMemoryBound(to: UInt8.self)
                var mask = [UInt8](repeating: 0, count: CELL_W * CELL_H)
                for y in 0..<CELL_H {
                    let s = y * ctx.bytesPerRow
                    let d = y * CELL_W
                    for x in 0..<CELL_W { mask[d + x] = buf[s + x * 4 + 3] }
                }
                rowMasks.append(mask)
            }
            newFrames.append(rowFrames)
            newMasks.append(rowMasks)
        }
        // 悬停/点击判定用"站姿轮廓"：行 0（idle）全部帧的并集，避免动画帧变化导致判定抖动
        var hm = [UInt8](repeating: 0, count: CELL_W * CELL_H)
        for m in newMasks[0] {
            for i in 0..<(CELL_W * CELL_H) { hm[i] = max(hm[i], m[i]) }
        }
        guard hm.contains(where: { $0 > 32 }) else { return false }
        frames = newFrames
        masks = newMasks
        hoverMask = hm
        extraClips = loadExtraClips()
        return true
    }

    private func extraActionsDirectory() -> URL? {
        if character.id == "roxy" {
            return Bundle.main.resourceURL?.appendingPathComponent("roxy-actions", isDirectory: true)
        }
        return character.atlasURL?.deletingLastPathComponent().appendingPathComponent("actions", isDirectory: true)
    }

    private func loadExtraClips() -> [String: ExtraClip] {
        guard let directory = extraActionsDirectory(),
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let image = NSImage(contentsOf: directory.appendingPathComponent("spritesheet.png")),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [:] }
        return Self.decodeExtraClips(data: data, image: cg)
    }

    /// Decode into a temporary collection; any malformed optional sidecar simply disables it.
    private static func decodeExtraClips(data: Data?, image: CGImage?) -> [String: ExtraClip] {
        guard let data = data, data.count <= 65_536, let cg = image,
              let spec = try? JSONDecoder().decode(ExtraActionManifest.self, from: data),
              spec.version == 1, spec.columns == COLS, (1...16).contains(spec.rows),
              spec.cellWidth == CELL_W * 2, spec.cellHeight == CELL_H * 2,
              cg.width == spec.columns * spec.cellWidth, cg.height == spec.rows * spec.cellHeight,
              [.premultipliedLast, .premultipliedFirst, .last, .first].contains(cg.alphaInfo),
              !spec.actions.isEmpty, spec.actions.count <= spec.rows,
              Set(spec.actions.map(\.id)).count == spec.actions.count,
              Set(spec.actions.map(\.row)).count == spec.actions.count,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [:] }
        var decoded: [String: ExtraClip] = [:]
        for action in spec.actions {
            guard PetCharacter.validID(action.id), action.id.count <= 48,
                  !["wave", "jump"].contains(action.id),
                  !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  action.title.count <= 40, action.title.rangeOfCharacter(from: .controlCharacters) == nil,
                  (0..<spec.rows).contains(action.row), (1...COLS).contains(action.frameCount),
                  action.frameDuration.isFinite, (0.03...2.0).contains(action.frameDuration) else { return [:] }
            var images: [NSImage] = []
            for col in 0..<action.frameCount {
                let rect = CGRect(x: col * spec.cellWidth, y: action.row * spec.cellHeight,
                                  width: spec.cellWidth, height: spec.cellHeight)
                guard let cell = cg.cropping(to: rect),
                      let context = CGContext(data: nil, width: CELL_W, height: CELL_H,
                                              bitsPerComponent: 8, bytesPerRow: CELL_W * 4,
                                              space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [:] }
                context.draw(cell, in: CGRect(x: 0, y: 0, width: CELL_W, height: CELL_H))
                let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
                var visible = 0
                for pixel in 0..<(CELL_W * CELL_H) where bytes[pixel * 4 + 3] > 64 { visible += 1 }
                guard visible > 500 else { return [:] }
                images.append(NSImage(cgImage: cell, size: NSSize(width: CELL_W, height: CELL_H)))
            }
            decoded[action.id] = ExtraClip(description: action, frames: images)
        }
        return decoded
    }

    private func oncePlayback(for kind: String) -> (row: Int, sequence: [(Int, Double)], extraID: String?)? {
        if kind == "jump" { return (4, JUMP_SEQ, nil) }
        if kind == "wave" { return (3, WAVE_SEQ, nil) }
        if let clip = extraClips[kind] { return (0, clip.sequence, kind) }
        return nil
    }

    private func setupWindow() {
        let size = NSSize(width: CGFloat(CELL_W) * WINDOW_SCALE,
                          height: CGFloat(CELL_H) * WINDOW_SCALE)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isMovable = false

        let v = PetView(frame: NSRect(origin: .zero, size: size))
        v.controller = self
        win.contentView = v
        window = win
        petView = v

        placeDefaultPosition()
        win.orderFrontRegardless()
    }

    private func placeDefaultPosition() {
        guard let win = window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        win.setFrameOrigin(NSPoint(x: vf.maxX - win.frame.width - 60, y: vf.minY + 70))
    }

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / TICK_FPS, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    // ---------- 说话（气泡）----------
    func speak(_ text: String, seconds: Double? = nil, fullText: String? = nil, resumeSid: String? = nil, resumeTty: String? = nil, resumeTerm: String? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = resolvedTitle(text)
        guard window != nil, !petHidden, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        bubbleCopyText = fullText ?? text
        bubbleResumeSid = resumeSid
        bubbleResumeTty = resumeTty
        bubbleResumeTerm = resumeTerm
        let size = bubbleSize(for: text)
        if bubbleWindow == nil {
            let bv = BubbleView(frame: NSRect(origin: .zero, size: size))
            bv.controller = self
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = bv
            bubbleWindow = w
            bubbleView = bv
        }
        bubbleView?.text = text
        bubbleWindow?.setContentSize(size)
        bubbleView?.frame = NSRect(origin: .zero, size: size)
        let dur = seconds ?? max(3.5, min(9.0, Double(text.count) * 0.22 + 2.0))
        bubbleHideAt = CACurrentMediaTime() + dur
        bubbleVisible = true
        updateBubblePosition()
        bubbleWindow?.orderFrontRegardless()
    }

    // 点击气泡：复制内容（优先全文）；若来自一次 Claude 会话输出 →
    // 先按 tty 聚焦它所在的终端窗口；确找不到才新开接续窗口
    func bubbleClicked() {
        guard let bub = bubbleView else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(bubbleCopyText.isEmpty ? bub.text : bubbleCopyText, forType: .string)
        guard let sid = bubbleResumeSid, !sid.isEmpty else { return }
        let tty = bubbleResumeTty
        let term = bubbleResumeTerm
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let focused = self.focusTerminal(tty: tty, term: term)
            if !focused {
                DispatchQueue.main.async { self.openResumeTerminal(sid: sid) }
            }
        }
    }

    // 定位终端窗口：① tty 精确到标签页；② TERM_PROGRAM 映射激活；③ 常见终端兜底
    private func focusTerminal(tty: String?, term: String?) -> Bool {
        var listCandidates: [NSRunningApplication] = []
        if let t = tty, !t.isEmpty, t != "??", t != "-" {
            let dev = "/dev/" + t
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first {
                let s = """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with tab in tabs of w
                            if (tty of tab as text) is "\(dev)" then
                                set selected tab of w to tab
                                set index of w to 1
                                activate
                                return "OK"
                            end if
                        end repeat
                    end repeat
                    return "LISTED"
                end tell
                """
                let r = runOsascript(s)
                if r == "OK" { return true }
                if r == "LISTED" { listCandidates.append(app) }
            }
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first {
                let s = """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with tab in tabs of w
                            repeat with sess in sessions of tab
                                if (tty of sess as text) is "\(dev)" then
                                    select w
                                    activate
                                    return "OK"
                                end if
                            end repeat
                        end repeat
                    end repeat
                    return "LISTED"
                end tell
                """
                let r = runOsascript(s)
                if r == "OK" { return true }
                if r == "LISTED" { listCandidates.append(app) }
            }
        }
        if let app = listCandidates.first {
            app.activate(options: [])
            return true
        }
        if let tp = term, !tp.isEmpty {
            let bidMap: [String: String] = [
                "Apple_Terminal": "com.apple.Terminal",
                "iTerm.app": "com.googlecode.iterm2",
                "WarpTerminal": "dev.warp.Warp-Stable",
                "ghostty": "com.mitchellh.ghostty",
                "WezTerm": "com.github.wez.wezterm",
                "kitty": "net.kovidgoyal.kitty",
            ]
            if let bid = bidMap[tp], let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.activate(options: [])
                return true
            }
            if tp.lowercased() == "cmux", let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app").first {
                app.activate(options: [])
                return true
            }
        }
        for bid in ["com.cmuxterm.app", "com.github.wez.wezterm", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty", "dev.warp.Warp-Stable"] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.activate(options: [])
                return true
            }
        }
        return false
    }

    private func runOsascript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            return nil
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openResumeTerminal(sid: String) {
        let path = NSTemporaryDirectory() + "Roxy接续会话.command"
        let script = "#!/bin/bash\ncd \"$HOME\"\nexec claude --resume \(sid)\n"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } catch {
            NSLog("Roxy: resume command failed: \(error)")
        }
    }

    private func updateBubblePosition() {
        guard let pet = window, let bub = bubbleWindow, bubbleVisible else { return }
        let pf = pet.frame
        var x = pf.midX - bub.frame.width / 2
        var y = pf.maxY + 6
        // 跟着桌宠所在的那块屏幕走；不能用 NSScreen.main（那是键盘焦点所在的屏幕，
        // 接了扩展屏时经常是另一块，会把气泡夹到别的显示器上）。
        let scr = pet.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(pf) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let scr = scr {
            let vf = scr.visibleFrame
            x = min(max(x, vf.minX + 6), vf.maxX - bub.frame.width - 6)
            if y + bub.frame.height > vf.maxY - 6 {
                y = pf.minY - bub.frame.height - 6   // 上方放不下 → 放下方
            }
            y = min(max(y, vf.minY + 6), vf.maxY - bub.frame.height - 6)
        }
        bub.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // ---------- 事件钩子 ----------
    func dragStarted(atMouseX x: CGFloat, atMouseY y: CGFloat) {
        acknowledgeDesktopReturn()
        cancelAmbientOnce()
        dragging = true
        dragMoved = false
        dragPrevX = x
        dragStartPoint = NSPoint(x: x, y: y)
        lastInteractAt = CACurrentMediaTime()
    }

    func dragEnded() {
        dragging = false
        if !pendingOnce.isEmpty {
            let k = pendingOnce
            let r = pendingOnceRepeats
            pendingOnce = ""
            pendingOnceRepeats = nil
            beginOnce(k, repeats: r, preserveChain: true)
        }
    }

    func startOnce(_ kind: String, repeats: Int? = nil) {
        beginOnce(kind, repeats: repeats)
    }

    private func beginOnce(_ kind: String, repeats: Int? = nil, ambient: Bool = false,
                           reason: AmbientReason? = nil, preserveChain: Bool = false) {
        guard oncePlayback(for: kind) != nil else { return }
        if !preserveChain { chainedExtraKind = nil }
        if dragging {
            pendingOnce = kind
            pendingOnceRepeats = repeats
            return
        }
        onceKind = kind
        onceRepeatsLeft = max(1, repeats ?? (kind == "wave" ? WAVE_REPEAT : 1))
        ambientOnce = ambient
        ambientReason = ambient ? reason : nil
        animKey = ""
        animElapsed = 0
    }

    private func cancelAmbientOnce() {
        guard ambientOnce else { return }
        onceKind = ""; onceRepeatsLeft = 0; ambientOnce = false; ambientReason = nil
        animKey = ""; animElapsed = 0
    }

    // Preserve the old completion wave in full, then append this costume's optional finish.
    private func acknowledgeDesktopReturn(at now: TimeInterval = Date().timeIntervalSince1970) {
        guard !petHidden, !systemActivity.isPaused else { return }
        systemActivity.acknowledgeReturn(at: now)
    }

    private func triggerCompletionReaction(activityNow: TimeInterval = Date().timeIntervalSince1970,
                                           workDuration: Double? = nil) {
        acknowledgeDesktopReturn(at: activityNow)
        triggerWave()
        if let id = completionExtraID(workDuration: workDuration) { chainedExtraKind = id }
    }

    // A reply adds a finish; it must not replace an in-flight or drag-queued user reaction.
    private func appendReplyExtraAction(activityNow: TimeInterval = Date().timeIntervalSince1970,
                                       workDuration: Double? = nil) {
        guard let id = completionExtraID(workDuration: workDuration) else { return }
        acknowledgeDesktopReturn(at: activityNow)
        if (!ambientOnce && !onceKind.isEmpty && onceRepeatsLeft > 0) || !pendingOnce.isEmpty {
            chainedExtraKind = id
        } else {
            startOnce(id, repeats: 1)
        }
    }

    func triggerWave() { startOnce("wave") }
    func triggerWaveOnce() { startOnce("wave", repeats: 1) }   // 单击说台词：只挥一遍手
    func triggerJump() { startOnce("jump") }

    // ---------- 主循环 ----------
    private func tick() {
        let now = CACurrentMediaTime()
        if lastTick == 0 { lastTick = now }
        let dt = min(now - lastTick, 0.25)
        lastTick = now
        guard window != nil else { return }

        pollClaudeState(dt: dt)
        pollDshBridge(dt: dt)
        pollDshBilling(dt: dt)
        pollHarnessDetection(dt: dt)
        pollSchedules(now: now, dt: dt)
        pollSystemActivity(now: now)

        // 情绪维护（本地）：久未互动 → lonely；被连续摸头 → shy（限时）
        if lastInteractAt == 0 { lastInteractAt = now }
        if mood == .shy {
            if now > moodUntil { mood = .calm }
        } else {
            mood = (now - lastInteractAt > 900) ? .lonely : .calm
        }

        // 悬停边沿：进入=被摸一下；移开 → 开启跟随窗口
        let hovering = isHovering()
        if hovering && !wasHovering {
            onPetted(now: now)
            // 鼠标放上来：跳 / 挥手交替出现（保证两种反应都常见到）；
            // "转头跟随"期间鼠标在旁边划进划出不算新触碰，不打断
            if now >= lookUntil {
                if nextTouchIsJump { triggerJump() } else { triggerWaveOnce() }
                nextTouchIsJump.toggle()
            }
        }
        if wasHovering && !hovering {
            cancelAmbientOnce()
            lookUntil = now + LOOK_WINDOW_SECONDS
        }
        wasHovering = hovering
        // 注视刚结束（到点）：小概率说一句
        if lookUntil > 0 && now >= lookUntil {
            lookUntil = 0
            if !hovering && !dragging && Double.random(in: 0..<1) < 0.2 {
                speak(randomOf(lines("look_end", LOOK_END_LINES)))
            }
        }

        // 拖动方向判定（位移超过点击阈值才算"拖起来"；纯点击不算，不播奔跑动画）
        if dragging {
            let mx = NSEvent.mouseLocation.x
            let my = NSEvent.mouseLocation.y
            if !dragMoved && hypot(mx - dragStartPoint.x, my - dragStartPoint.y) > CLICK_MAX_MOVE {
                dragMoved = true
                if Double.random(in: 0..<1) < 0.12 { speak(randomOf(lines("drag", DRAG_LINES))) }
            }
            let d = mx - dragPrevX
            if d > 0.3 { dragRight = true }
            else if d < -0.3 { dragRight = false }
            dragPrevX = mx
        }

        pollExtraActions(now: now, dt: dt)

        // ---- 显示决策（优先级从高到低）----
        if onceRepeatsLeft <= 0 { onceKind = "" }

        var key = ""
        var seqRow = 0
        var seq: [(Int, Double)]? = nil
        var extraID: String? = nil
        var loop = true
        var lookDirNow: Int? = nil

        if dragging && dragMoved {
            key = dragRight ? "runR" : "runL"
            seqRow = dragRight ? 1 : 2
            seq = RUN_SEQ
        } else if !onceKind.isEmpty {
            key = "once-" + onceKind
            if let playback = oncePlayback(for: onceKind) {
                seqRow = playback.row
                seq = playback.sequence
                extraID = playback.extraID
            }
            loop = false
        } else if now < lookUntil {
            key = "look"
            lookDirNow = dirToMouse()
        } else if glanceUntil > 0 && now < glanceUntil {
            key = "glance"
            lookDirNow = glanceDir
        } else if aiBusy {
            key = "busy"
            seqRow = 7
            seq = WORK_SEQ
        } else if workState == "working" {
            key = "work"
            seqRow = 7
            seq = WORK_SEQ
        } else {
            key = "idle"
            seqRow = 0
            seq = IDLE_SEQ
        }

        if key != animKey {
            animKey = key
            animElapsed = 0
        }

        if let seq = seq {
            advanceSequence(row: seqRow, sequence: seq, loop: loop, extraID: extraID, dt: dt)
        } else if let d = lookDirNow {
            lastLookDir = d
            let rc = dirToRowCol(d)
            show(row: rc.row, col: rc.col)
            maybeDirSpeak(dir: d, now: now)
        }

        // ---------- 待机拟真眨眼 ----------
        // 真人式节律：间隔 1.8~4.2 秒随机；12% 概率补一下连眨；进入待机后首次 1.2~2.5 秒随机。
        // 一次眨眼＝整弧播放 BLINK_SEQ（一睁→半闭→闭→半睁→睁），而不是闪一帧闭眼。
        if key == "idle" {
            let blinkTotal = BLINK_SEQ.reduce(0) { $0 + $1.1 }
            if blinkUntil > 0 && now >= blinkUntil { blinkUntil = 0 }
            if blinkDoubleAt > 0 && now >= blinkDoubleAt {
                blinkDoubleAt = 0
                blinkUntil = now + blinkTotal
            }
            if blinkAt == 0 { blinkAt = now + Double.random(in: 1.2...2.5) }
            if blinkUntil == 0 && now >= blinkAt {
                blinkUntil = now + blinkTotal
                blinkAt = now + Double.random(in: 1.8...4.2)
                if Double.random(in: 0..<1) < 0.12 {
                    blinkDoubleAt = blinkUntil + Double.random(in: 0.22...0.32)
                }
            }
            if blinkUntil > 0 && now < blinkUntil {
                let e = blinkTotal - (blinkUntil - now)   // 本次眨眼已进行的时长
                var acc = 0.0
                var c = BLINK_SEQ.last!.0
                for (col, d) in BLINK_SEQ { acc += d; if e < acc { c = col; break } }
                show(row: 0, col: c)
            }
        } else {
            blinkAt = 0
            blinkUntil = 0
            blinkDoubleAt = 0
        }

        // ---------- 待机小动作：偶尔侧头瞥一眼（让待机不呆板；与"点头"无关）----------
        if key == "idle" || key == "glance" {
            if glanceUntil > 0 && now >= glanceUntil { glanceUntil = 0 }
            if glanceAt == 0 { glanceAt = now + Double.random(in: 3.5...7.0) }
            if glanceUntil == 0 && now >= glanceAt {
                glanceUntil = now + Double.random(in: 0.5...0.9)
                glanceDir = [4, 12, 4, 12, 6, 10].randomElement() ?? 4   // 以左右为主，偶尔斜下
                glanceAt = now + Double.random(in: 5.0...11.0)
            }
        } else {
            glanceAt = 0
            glanceUntil = 0
        }

        // 气泡维护
        if bubbleVisible {
            if now >= bubbleHideAt {
                bubbleVisible = false
                bubbleWindow?.orderOut(nil)
            } else {
                updateBubblePosition()
            }
        }
    }

    private func advanceSequence(row: Int, sequence: [(Int, Double)], loop: Bool, extraID: String?, dt: Double) {
        if extraID != nil && dragging && dragMoved { return }
        let total = sequence.reduce(0) { $0 + $1.1 }
        guard total > 0, !sequence.isEmpty else { return }
        animElapsed += dt
        if loop {
            if animElapsed >= total { animElapsed = animElapsed.truncatingRemainder(dividingBy: total) }
        } else {
            while animElapsed >= total && onceRepeatsLeft > 0 {
                animElapsed -= total
                onceRepeatsLeft -= 1
            }
            if onceRepeatsLeft <= 0 {
                let next = chainedExtraKind
                chainedExtraKind = nil
                onceKind = ""; ambientOnce = false; ambientReason = nil; animKey = ""; animElapsed = 0
                if let next = next, let clip = extraClips[next] {
                    if !pendingOnce.isEmpty {
                        // A held mouse may finish the old clip before dragEnded consumes its queue.
                        chainedExtraKind = next
                        show(row: 0, col: 0)
                    } else {
                        beginOnce(next, repeats: 1)
                        if !dragging { showExtra(clip, col: 0) }
                    }
                } else if pendingOnce.isEmpty, let clicked = queuedClickKind {
                    queuedClickKind = nil
                    beginOnce(clicked, repeats: 1)
                } else {
                    show(row: 0, col: 0)
                }
                return
            }
        }
        var elapsed = 0.0
        var frame = sequence.last!.0
        for (col, duration) in sequence {
            elapsed += duration
            if animElapsed < elapsed { frame = col; break }
        }
        if let id = extraID, let clip = extraClips[id] { showExtra(clip, col: frame) }
        else { show(row: row, col: frame) }
    }

    private func automaticExtraActionIsUnblocked(now: CFTimeInterval) -> Bool {
        !dragging && onceKind.isEmpty && pendingOnce.isEmpty && chainedExtraKind == nil
            && now >= lookUntil && now >= glanceUntil
    }

    private func pollExtraActions(now: CFTimeInterval, dt: Double,
                                  activityNow: TimeInterval = Date().timeIntervalSince1970) {
        guard let behavior = extraBehavior, !extraClips.isEmpty, !petHidden,
              systemActivity.canAnimateAutomatically else { return }
        let working = aiBusy || workState == "working"
        if working {
            if ambientOnce && ambientReason != .work { cancelAmbientOnce() }
            if nextExtraWorkActionAt == 0 { nextExtraWorkActionAt = now + Double.random(in: 24...45) }
            // Keep every old work cycle; add practice only during a quiet input gap.
            let boundary = ["busy", "work"].contains(animKey) && animElapsed + dt >= WORK_SEQ.reduce(0) { $0 + $1.1 }
            if now >= nextExtraWorkActionAt, boundary, automaticExtraActionIsUnblocked(now: now),
               (systemActivity.idleSeconds ?? 0) >= 3, extraClips[behavior.work] != nil {
                beginOnce(contextAction(behavior.work, alternatives: [], context: "work"), repeats: 1, ambient: true, reason: .work)
                nextExtraWorkActionAt = now + Double.random(in: 24...45)
            }
            return
        }
        nextExtraWorkActionAt = 0
        guard automaticExtraActionIsUnblocked(now: now) else { return }
        if systemActivity.pendingReturnSalute, extraClips[behavior.salute] != nil,
           systemActivity.takeReturnSalute(at: activityNow) {
            beginOnce(contextAction(behavior.salute, alternatives: ["wave"], context: "return"), repeats: 1, ambient: true, reason: .returnSalute)
            return
        }
        if (systemActivity.idleSeconds ?? 0) >= (deterministicActionChecks ? 60 : nextIdleDelay), !systemActivity.idlePosePlayed,
           extraClips[behavior.idle] != nil {
            systemActivity.idlePosePlayed = true
            nextIdleDelay = Double.random(in: 60...100)
            beginOnce(contextAction(behavior.idle, alternatives: ["daily-focus"], context: "idle"), repeats: 1, ambient: true, reason: .idle)
        }
    }

    // ---------- 行为调度：打招呼 / 整点 / 闲聊 / 电池 ----------
    private func pollSchedules(now: CFTimeInterval, dt: Double) {
        // 打招呼
        if !greeted && now - startTime > GREET_DELAY {
            greeted = true
            speak(randomOf(lines("greeting", GREETINGS)))
            triggerWave()
        }
        // 整点报时
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        if let h = comps.hour, let m = comps.minute, m == 0, h != lastChimeHour {
            lastChimeHour = h
            let quiet = h >= CHIME_QUIET_FROM || h < CHIME_QUIET_TO
            if !quiet {
                speak(characterHourlyLine(h))
                triggerJump()
            }
        }
        // 随机闲聊
        if nextChatAt == 0 { nextChatAt = now + Double.random(in: CHAT_INTERVAL_MIN...CHAT_INTERVAL_MAX) }
        if now >= nextChatAt {
            nextChatAt = now + Double.random(in: CHAT_INTERVAL_MIN...CHAT_INTERVAL_MAX)
            if !dragging && !bubbleVisible {
                speak(pickChatLine())
            }
        }
        // 电池（每 30 秒）
        batteryAcc += dt
        if batteryAcc >= 30 {
            batteryAcc = 0
            pollBattery()
        }
    }

    private func characterHourlyLine(_ hour: Int) -> String {
        if character.isRoxy { return hourlyLine(hour) }
        let key: String
        switch hour {
        case 7...11: key = "hourly_morning"
        case 12: key = "hourly_noon"
        case 13...17: key = "hourly_day"
        case 18...22: key = "hourly_evening"
        default: key = "hourly_default"
        }
        let template = randomOf(lines(key, []))
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return template.isEmpty ? "现在是\(hour)点。" : template.replacingOccurrences(of: "{h}", with: String(h12))
    }

    private func pollBattery() {
        DispatchQueue.global().async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["-g", "batt"]
            let out = Pipe()
            p.standardOutput = out
            try? p.run()
            p.waitUntilExit()
            let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let status = PetController.parseBatteryStatus(s) {
                DispatchQueue.main.async { self?.applyBattery(level: status.level, charging: status.charging) }
            }
        }
    }

    private static func parseBatteryStatus(_ text: String) -> (level: Int, charging: Bool)? {
        guard let batteryLine = text.split(separator: "\n").first(where: { $0.contains("%") }),
              let range = batteryLine.range(of: #"(\d+)%"#, options: .regularExpression),
              let level = Int(batteryLine[range].dropLast()), (0...100).contains(level) else { return nil }
        let states = batteryLine.split(separator: ";").dropFirst().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let charging: Bool
        if states.contains("discharging") || states.contains("not charging") { charging = false }
        else if states.contains("charging") || states.contains("charged") || states.contains("finishing charge") { charging = true }
        else { charging = text.contains("'AC Power'") }
        return (level, charging)
    }

    private func applyBattery(level: Int, charging: Bool) {
        guard level >= 0 else { return }
        battLevel = level
        battCharging = charging
        if charging {
            battWarnStep = 0
            if level >= 100 && !battFullWarned {
                battFullWarned = true
                speak(randomOf(lines("battery_full", BATTERY_FULL)))
                triggerWave()
            }
            if level < 95 { battFullWarned = false }
        } else {
            battFullWarned = false
            if level <= 10 && battWarnStep < 2 {
                battWarnStep = 2
                speak(randomOf(lines("battery10", BATTERY_10)))
                triggerJump()
            } else if level <= 20 && battWarnStep < 1 {
                battWarnStep = 1
                speak(randomOf(lines("battery20", BATTERY_20)))
                triggerJump()
            }
        }
    }

    // ---------- 鼠标方位 → 16 方向帧 ----------
    private func dirToMouse() -> Int {
        guard let win = window else { return max(lastLookDir, 0) }
        let f = win.frame
        let cx = f.origin.x + f.width * HEAD_CENTER_X_RATIO
        let cy = f.origin.y + f.height * HEAD_CENTER_Y_RATIO
        let dx = NSEvent.mouseLocation.x - cx
        let dy = NSEvent.mouseLocation.y - cy
        if hypot(dx, dy) <= 1 { return max(lastLookDir, 0) }
        let deg = atan2(dx, dy) * 180.0 / .pi
        return ((Int((deg / 22.5).rounded()) % 16) + 16) % 16
    }

    // ---------- 悬停判定（稳定站姿轮廓）----------
    private func isHovering() -> Bool {
        guard let win = window else { return false }
        let f = win.frame
        let m = NSEvent.mouseLocation
        guard f.contains(m) else { return false }
        let p = NSPoint(x: m.x - f.origin.x, y: m.y - f.origin.y)
        return isOpaquePixel(viewPoint: p)
    }

    // ---------- Claude Code 状态 ----------
    private func pollClaudeState(dt: Double) {
        statePollAcc += dt
        if statePollAcc < STATE_POLL_INTERVAL { return }
        statePollAcc = 0
        let d = UserDefaults.standard
        let nowEpoch = Date().timeIntervalSince1970

        var working = false
        var noticeTS = 0.0
        var doneTS = 0.0
        var doneSrc = ""
        var workingSources = Set<String>()

        // 读取单个来源的状态文件（state\n时间戳），汇总为 working / notice / done
        func consider(_ src: String, _ file: String) {
            guard let data = FileManager.default.contents(atPath: file),
                  let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !lines.isEmpty else { return }
            let st = lines[0]
            let ts = lines.count > 1 ? (Double(lines[1]) ?? 0) : 0
            switch st {
            case "working":
                if nowEpoch - ts >= 0 && nowEpoch - ts < WORK_TIMEOUT_SECONDS {
                    working = true
                    workingSources.insert(src)
                }
            case "notice":
                if nowEpoch - ts < 120 && ts > noticeTS { noticeTS = ts }
            case "done":
                if nowEpoch - ts < 120 && ts > doneTS { doneTS = ts; doneSrc = src }
            default: break
            }
        }

        let base = NSHomeDirectory() + "/.roxy-pet/"
        let watchClaude = d.object(forKey: "roxyWatchClaude") == nil ? true : d.bool(forKey: "roxyWatchClaude")
        if watchClaude {
            if FileManager.default.fileExists(atPath: base + "state.claude") {
                consider("claude", base + "state.claude")
            } else {
                consider("claude", base + "state")   // 兼容旧版单文件
            }
        }
        if d.bool(forKey: "roxyWatchCodex") {
            consider("codex", base + "state.codex")
        }
        if d.object(forKey: "roxyWatchDsh") == nil ? true : d.bool(forKey: "roxyWatchDsh") {
            consider("dsh", base + "state.dsh")
        }
        if d.bool(forKey: "roxyWatchOpencode") {
            // opencode 无官方钩子：用运行中的 `opencode run` 进程做"进行中"信号
            let running = PetController.processRunning(match: "opencode run")
            if running {
                working = true
                ocWatchRunning = true
            } else if ocWatchRunning {
                ocWatchRunning = false
                if !aiBusy { triggerCompletionReaction(); speak(randomOf(lines("done", DONE_LINES))) }
            }
        }

        let nowMonotonic = CACurrentMediaTime()
        // Read the finishing source's duration before clearing intervals no longer working.
        let completedWorkDuration = completionWorkTiming.duration(for: doneSrc, at: nowMonotonic)
        completionWorkTiming.update(workingSources: workingSources, at: nowMonotonic)
        workState = working ? "working" : "idle"

        if noticeTS > lastOnceTS {
            lastOnceTS = noticeTS
            triggerWave()
            speak(randomOf(lines("notice", NOTICE_LINES)))
        } else if doneTS > lastOnceTS {
            lastOnceTS = doneTS
            if !aiBusy {
                // 她转派的任务结果由 runClaudeTask 统一展示，避免重复
                triggerCompletionReaction(workDuration: completedWorkDuration)
                speakDoneReport(from: doneSrc)
                if doneSrc == "dsh" { refreshDshBalance(speakChange: true) }
            }
        }
    }

    // ---------- DeepSeek Harness（dsh）----------
    // dsh-plugin-roxy 会把会话状态写到 state.dsh / last_reply.dsh，
    // 把权限请求写到 dsh/approval.json；这里负责心跳与批准弹窗。
    private func pollDshBridge(dt: Double) {
        dshHeartbeatAcc += dt
        if dshHeartbeatAcc >= 5 {
            dshHeartbeatAcc = 0
            let dir = NSHomeDirectory() + "/.roxy-pet/dsh"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? String(Date().timeIntervalSince1970)
                .write(toFile: dir + "/roxy-heartbeat", atomically: true, encoding: .utf8)
        }

        dshApprovalAcc += dt
        if dshApprovalAcc < 0.6 { return }
        dshApprovalAcc = 0
        let dir = NSHomeDirectory() + "/.roxy-pet/dsh"
        let file = dir + "/approval.json"
        guard let data = FileManager.default.contents(atPath: file),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty, id != lastDshApprovalId else { return }
        if let exp = obj["expiresAt"] as? Double, exp > 0, Date().timeIntervalSince1970 * 1000 > exp { return }

        lastDshApprovalId = id
        let tool = (obj["toolName"] as? String) ?? "工具"
        let reason = (obj["reason"] as? String) ?? ""
        let alert = NSAlert()
        alert.messageText = "Harness 请求批准"
        alert.informativeText = reason.isEmpty ? "工具：\(tool)" : "工具：\(tool)\n原因：\(reason)"
        alert.addButton(withTitle: "允许一次")
        alert.addButton(withTitle: "拒绝")
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        let decision = resp == .alertFirstButtonReturn ? "allow" : "deny"
        if let out = try? JSONSerialization.data(withJSONObject: ["id": id, "decision": decision]) {
            try? out.write(to: URL(fileURLWithPath: dir + "/approval-reply.json"))
        }
        speak(decision == "allow" ? "好，这次我批准了。" : "这次我拒绝了。")
    }

    /// 运行途中装了 Harness 也能自动接上：未连接时每 5 分钟探测一次。
    private func pollHarnessDetection(dt: Double) {
        guard !PetController.isDshConnected() else { return }
        harnessDetectAcc += dt
        guard harnessDetectAcc >= 300 else { return }
        harnessDetectAcc = 0
        PetController.detectHarnesses()
        if PetController.isDshConnected() {
            refreshHarnessDetection(announce: true)
        }
    }

    /// DeepSeek Harness：对话同步刷新 + 余额实时显示（每 60 秒；开关在设置里）。
    private func pollDshBilling(dt: Double) {
        guard PetController.isDshConnected() else { return }
        // 记录窗口开着时，定期把 DSH 对话拉进来（桥插件写文件，不占 token、不打扰会话）
        dshHistoryAcc += dt
        if dshHistoryAcc >= 2 {
            dshHistoryAcc = 0
            if historyWindow?.isVisible == true {
                let before = dshHistorySig
                loadDshHistory()
                let after = "\(dshHistory.count)-\(dshHistory.last?.t ?? 0)"
                if before != after { refreshHistoryWindow() }
            }
        }
        // 余额：默认每 60 秒刷新一次
        let d = UserDefaults.standard
        let live = d.object(forKey: "roxyDshBalanceLive") == nil ? true : d.bool(forKey: "roxyDshBalanceLive")
        guard live else { return }
        dshBalanceAcc += dt
        if dshBalanceAcc >= 60 && !dshBalanceInFlight {
            dshBalanceAcc = 0
            refreshDshBalance(speakChange: false)
        }
    }

    /// 拉一次官方余额；失败保持旧值（不打扰）。
    private func refreshDshBalance(speakChange: Bool) {
        guard !dshBalanceInFlight else { return }
        let d = UserDefaults.standard
        if d.object(forKey: "roxyDshBalanceLive") != nil, !d.bool(forKey: "roxyDshBalanceLive") { return }
        guard PetController.apiConfig() != nil else { return }
        dshBalanceInFlight = true
        PetController.fetchDeepSeekBalance { [weak self] text, total in
            DispatchQueue.main.async {
                guard let self else { return }
                self.dshBalanceInFlight = false
                if let total {
                    if speakChange, let prev = self.dshBalanceTotal, total < prev - 0.001 {
                        self.speak("这轮花了 ¥" + String(format: "%.2f", prev - total)
                                   + "，余额 ¥" + String(format: "%.2f", total), seconds: 6)
                    }
                    self.dshBalanceTotal = total
                }
                if let text { self.dshBalanceText = text }
                self.refreshDshStatusLine()
            }
        }
    }

    /// 设置窗口里的「DeepSeek Harness」状态行（连接状态 + 余额）
    private func refreshDshStatusLine() {
        guard let label = swDshStatusLabel else { return }
        let connected = PetController.harnessPaths["dsh"] != nil
        if let path = PetController.harnessPaths["dsh"] {
            var line = "已连接 · " + path
            if !dshBalanceText.isEmpty { line += "\n" + dshBalanceText }
            label.stringValue = line
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = "未连接——先安装 Harness，或点「重新检测」"
            label.textColor = .systemOrange
        }
        for v in swDshExtraViews { v.isHidden = !connected }
        // 余额变化时让菜单里的「DeepSeek Harness」一栏也跟着更新
        if settingsWindow == nil || settingsWindow?.isVisible == false {
            statusItem?.menu = makeMenu(forStatusBar: true)
        }
    }

    // 完工播报：优先转述实际回复摘要（30 秒内新鲜的），否则用台词库
    private func speakDoneReport(from src: String) {
        let base = NSHomeDirectory() + "/.roxy-pet/"
        if src == "dsh" {
            let rp3 = base + "last_reply.dsh"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: rp3),
               let mt = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(mt) < 30,
               let txt = try? String(contentsOfFile: rp3, encoding: .utf8) {
                let t = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    speak(t.count > 160 ? String(t.prefix(160)) + "…" : t, fullText: t)
                    return
                }
            }
            speak(randomOf(lines("done", DONE_LINES)))
            return
        }
        if src == "codex" {
            let rp2 = base + "last_reply.codex"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: rp2),
               let mt = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(mt) < 30,
               let txt = try? String(contentsOfFile: rp2, encoding: .utf8) {
                let t = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    speak(t.count > 160 ? String(t.prefix(160)) + "…" : t, fullText: t)
                    return
                }
            }
            speak(randomOf(lines("done", DONE_LINES)))
            return
        }
        let rp = base + "last_reply"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: rp),
           let mt = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mt) < 30,
           let txt = try? String(contentsOfFile: rp, encoding: .utf8) {
            let t = txt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                var sid: String?
                if let sd = try? String(contentsOfFile: NSHomeDirectory() + "/.roxy-pet/last_session", encoding: .utf8) {
                    let s = sd.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if !s.isEmpty { sid = s }
                }
                var tty: String?
                var term: String?
                if let td = try? String(contentsOfFile: NSHomeDirectory() + "/.roxy-pet/last_tty", encoding: .utf8) {
                    let ls = td.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    if ls.count > 0, !ls[0].isEmpty, ls[0] != "??" { tty = ls[0] }
                    if ls.count > 1, !ls[1].isEmpty { term = ls[1] }
                }
                speak(t.count > 160 ? String(t.prefix(160)) + "…" : t, fullText: t, resumeSid: sid, resumeTty: tty, resumeTerm: term)
                return
            }
        }
        speak(randomOf(lines("done", DONE_LINES)))
    }

    // ---------- 本地台词路由（情境/情绪；零 token，纯逻辑判断）----------
    private func onPetted(now: CFTimeInterval) {
        acknowledgeDesktopReturn()
        lastInteractAt = now
        if now - lastPetAt > 120 { petStreak = 0 }
        lastPetAt = now
        petStreak += 1
        if petStreak >= 4 && mood != .shy {
            mood = .shy
            moodUntil = now + 180
        }
        if Double.random(in: 0..<1) < 0.15 { speak(randomOf(lines("hover", HOVER_LINES))) }
    }

    // 转头跟随时，小概率冲当前方位说一句（16 档方向归并为 8 个方位池）
    private func maybeDirSpeak(dir: Int, now: CFTimeInterval) {
        let slot = ((Int((Double(dir) / 2.0).rounded()) % 8) + 8) % 8
        guard slot != lastDirSpokenSlot else { return }
        guard now - lastDirSpokeAt > 6 else { return }
        guard Double.random(in: 0..<1) < 0.18 else { return }
        guard DIR_LINES.indices.contains(slot), !DIR_LINES[slot].isEmpty else { return }
        lastDirSpokenSlot = slot
        lastDirSpokeAt = now
        let keys = ["up", "up_right", "right", "down_right", "down", "down_left", "left", "up_left"]
        speak(randomOf(lines(keys[slot], DIR_LINES[slot])))
    }

    private func pickChatLine() -> String {
        let comps = Calendar.current.dateComponents([.hour, .weekday], from: Date())
        let h = comps.hour ?? 12
        let wd = comps.weekday ?? 2
        var pool: [String] = []
        if h >= 23 || h < 5 { pool += lines("night", NIGHT_LINES) }
        else if h >= 5 && h < 11 { pool += lines("morning", MORNING_LINES) }
        else if h >= 17 { pool += lines("evening", EVENING_LINES) }
        else { pool += lines("day", DAY_LINES) }
        if wd == 1 || wd == 7 { pool += lines("weekend", WEEKEND_LINES) } else { pool += lines("workday", WORKDAY_LINES) }
        pool += lines("chat", CHAT_LINES)
        switch mood {
        case .shy: pool += lines("hover", HOVER_LINES)
        case .lonely: pool += lines("lonely", LONELY_LINES)
        case .calm: break
        }
        return pool.randomElement() ?? randomOf(lines("chat", CHAT_LINES))
    }

    // ---------- 台词扩展：内置批次（speech.swift）+ 用户自定义（~/.roxy-pet/speech.json）----------
    private func loadSpeechExtras() {
        func appendExtras(_ arr: inout [String], _ extra: [String]) {
            for line in extra {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !arr.contains(t) { arr.append(t) }
            }
        }
        appendExtras(&GREETINGS, GREET_EXTRA)
        appendExtras(&CHAT_LINES, CHAT_EXTRA)
        appendExtras(&HOVER_LINES, HOVER_EXTRA)
        appendExtras(&DRAG_LINES, DRAG_EXTRA)
        appendExtras(&LOOK_END_LINES, LOOK_END_EXTRA)
        appendExtras(&LONELY_LINES, LONELY_EXTRA)
        appendExtras(&MORNING_LINES, MORNING_EXTRA)
        appendExtras(&DAY_LINES, DAY_EXTRA)
        appendExtras(&EVENING_LINES, EVENING_EXTRA)
        appendExtras(&NIGHT_LINES, NIGHT_EXTRA)
        appendExtras(&WEEKEND_LINES, WEEKEND_EXTRA)
        appendExtras(&WORKDAY_LINES, WORKDAY_EXTRA)
        appendExtras(&BATTERY_20, BATTERY20_EXTRA)
        appendExtras(&BATTERY_10, BATTERY10_EXTRA)
        appendExtras(&BATTERY_FULL, BATTERYFULL_EXTRA)
        appendExtras(&DONE_LINES, DONE_EXTRA)
        appendExtras(&NOTICE_LINES, NOTICE_EXTRA)

        let path = NSHomeDirectory() + "/.roxy-pet/speech.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return }
        appendExtras(&GREETINGS, obj["greeting"] ?? [])
        appendExtras(&CHAT_LINES, obj["chat"] ?? [])
        appendExtras(&HOVER_LINES, obj["hover"] ?? [])
        appendExtras(&DRAG_LINES, obj["drag"] ?? [])
        appendExtras(&LOOK_END_LINES, obj["look_end"] ?? [])
        appendExtras(&LONELY_LINES, obj["lonely"] ?? [])
        appendExtras(&MORNING_LINES, obj["morning"] ?? [])
        appendExtras(&DAY_LINES, obj["day"] ?? [])
        appendExtras(&EVENING_LINES, obj["evening"] ?? [])
        appendExtras(&NIGHT_LINES, obj["night"] ?? [])
        appendExtras(&WEEKEND_LINES, obj["weekend"] ?? [])
        appendExtras(&WORKDAY_LINES, obj["workday"] ?? [])
        appendExtras(&BATTERY_20, obj["battery20"] ?? [])
        appendExtras(&BATTERY_10, obj["battery10"] ?? [])
        appendExtras(&BATTERY_FULL, obj["battery_full"] ?? [])
        appendExtras(&DONE_LINES, obj["done"] ?? [])
        appendExtras(&NOTICE_LINES, obj["notice"] ?? [])
    }

    // ---------- 本地说话（点选；零 token 消耗）----------
    @objc private func sayLocal() {        // 菜单「说句话（本地台词）」入口：说一句 + 挥一遍手
        speakLocalLine()
        triggerWaveOnce()
    }

    private func speakLocalLine() {
        setPetHidden(false)
        let pool = lines("chat", CHAT_LINES).filter { $0 != lastSpokenLine }
        let line = pool.randomElement() ?? randomOf(lines("chat", CHAT_LINES))
        lastSpokenLine = line
        speak(line)
    }

    // ---------- 看屏幕（透视魔法）：截图 → 本地 LM Studio 视觉模型 → 洛琪希口吻评论；全程不出本机 ----------
    @objc private func lookAtScreen() {
        setPetHidden(false)
        if aiBusy {
            speak("……我还在忙上一件事，请稍等一下哦。")
            return
        }
        guard PetController.hasAPIConfig() else {
            speak("看屏幕前需要先配置 API。")
            promptForAPISettings()
            return
        }
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.roxy-pet/peek-retry")
        if !CGPreflightScreenCaptureAccess() {
            if !requestScreenPermission() { return }
        }
        aiBusy = true
        speak(character.isRoxy ? "嗯……让我用透视魔法看一眼。" : "让我看看。", seconds: 8)
        let systemPrompt = characterPersonaSystem("你正在看用户授权提供的屏幕截图。用 1~2 句中文评论可见内容（40 字以内），只输出台词。")
        DispatchQueue.global().async { [weak self] in
            let result = PetController.screenPeek(systemPrompt: systemPrompt)
            DispatchQueue.main.async {
                self?.aiBusy = false
                self?.speak(result)
            }
        }
    }

    // 屏幕录制权限：模态弹窗引导，直到完成交互（授权成功 / 选择重启 / 取消）
    private func requestScreenPermission() -> Bool {
        var checkFailed = false
        while true {
            let alert = NSAlert()
            alert.messageText = "\(characterName)需要「屏幕录制」权限"
            if checkFailed {
                alert.informativeText = "还没检测到授权——如果刚刚勾选，可能需要重启我才能识别。可以点「帮我重启再看」，或回到「打开设置」再确认一下勾选。"
            } else {
                alert.informativeText = "macOS 要求应用截屏前必须先获得授权。\n\n请点「打开设置」→ 在「屏幕录制」里勾选「Roxy」（如有多条旧记录，请先移除旧条目）→ 回来点「检查并继续」。"
            }
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: checkFailed ? "帮我重启再看" : "检查并继续")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            let r = alert.runModal()
            if r == .alertFirstButtonReturn {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(u)
                }
                continue
            }
            if r == .alertSecondButtonReturn {
                if CGPreflightScreenCaptureAccess() { return true }
                if checkFailed {
                    try? "1".write(toFile: NSHomeDirectory() + "/.roxy-pet/peek-retry", atomically: true, encoding: .utf8)
                    speak("好的，我重启一下就回来。", seconds: 8)
                    relaunchAfter(seconds: 2)
                    return false
                }
                checkFailed = true
                continue
            }
            return false
        }
    }

    // 延迟重启自己（等用户完成屏幕录制授权后自动再试）
    private func relaunchAfter(seconds: Int) {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep \(seconds); open \"\(path)\""]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
    }

    private static func screenPeek(systemPrompt: String) -> String {
        let shot = "/tmp/roxy-view.png"
        let small = "/tmp/roxy-view-small.png"
        try? FileManager.default.removeItem(atPath: shot)
        try? FileManager.default.removeItem(atPath: small)
        let sc = Process()
        sc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        sc.arguments = ["-x", shot]
        try? sc.run()
        sc.waitUntilExit()
        guard FileManager.default.fileExists(atPath: shot) else {
            dbg("peek: screencapture produced nothing")
            return "唔……屏幕好像被结界挡住了，看不太清。稍后再试一次好吗？"
        }
        let sp = Process()
        sp.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sp.arguments = ["-Z", "1440", shot, "--out", small]
        try? sp.run()
        sp.waitUntilExit()
        let imgPath = FileManager.default.fileExists(atPath: small) ? small : shot
        defer {
            try? FileManager.default.removeItem(atPath: shot)
            try? FileManager.default.removeItem(atPath: small)
        }
        guard let data = FileManager.default.contents(atPath: imgPath) else {
            dbg("peek: image read failed")
            return "唔……画面读取失败了。"
        }
        dbg("peek: screenshot \(data.count) bytes, sending to API")
        let b64 = data.base64EncodedString()
        let sys = systemPrompt
        let userText = "这是用户的屏幕截图。请按人设评论。"
        // 主路径：接入的 API（Anthropic 兼容、支持视觉）
        if let t = askVisionAPI(system: sys, userText: userText, imageB64: b64) { return t }
        // 备选：本地 LM Studio（若在运行且有视觉模型）
        if let t = askLMStudio(system: sys, userText: userText, imageB64: b64) { return t }
        return "暂时连接不上，稍后再试一次吧。"
    }

    // 主路径：走已接入的 API（从 ~/.claude/settings.json 读取端点与凭证）
    /// API 配置解析：优先用桌宠内「API 设置」填写的值，未填则沿用 ~/.claude/settings.json
    private static func apiConfig() -> (base: URL, key: String, model: String)? {
        let d = UserDefaults.standard
        var baseStr = d.string(forKey: "roxyApiBase") ?? ""
        var key = d.string(forKey: "roxyApiKey") ?? ""
        var model = d.string(forKey: "roxyApiModel") ?? ""
        if baseStr.isEmpty || key.isEmpty {
            if let cfgData = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json"),
               let cfg = (try? JSONSerialization.jsonObject(with: cfgData)) as? [String: Any],
               let env = cfg["env"] as? [String: String] {
                if baseStr.isEmpty { baseStr = env["ANTHROPIC_BASE_URL"] ?? "" }
                if key.isEmpty { key = env["ANTHROPIC_AUTH_TOKEN"] ?? "" }
                if model.isEmpty { model = env["ANTHROPIC_MODEL"] ?? "" }
            }
        }
        guard !baseStr.isEmpty, !key.isEmpty, let base = URL(string: baseStr) else { return nil }
        if model.isEmpty { model = "claude-sonnet-5-5" }
        if let r = model.range(of: "[") { model = String(model[..<r.lowerBound]) }
        return (base, key, model)
    }

    private static func hasAPIConfig() -> Bool { apiConfig() != nil }

    /// 纯文本直连 API（聊天用）
    private static func askTextAPI(system: String, userText: String) -> String? {
        guard let (base, key, model) = apiConfig() else {
            dbg("api-text: no config")
            return nil
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "system": system,
            "messages": [["role": "user", "content": userText]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = bodyData
        guard let resp = httpJSON(req),
              let content = resp["content"] as? [[String: Any]] else {
            dbg("api-text: bad response")
            return nil
        }
        for block in content {
            if (block["type"] as? String) == "text",
               let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                dbg("api-text ok: \(t.prefix(60))")
                return t
            }
        }
        dbg("api-text: no text block (stop=\(resp["stop_reason"] ?? "?"))")
        return nil
    }

    private static func askVisionAPI(system: String, userText: String, imageB64: String) -> String? {
        guard let (base, key, model) = apiConfig() else {
            dbg("api: no config")
            return nil
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "system": system,
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": userText],
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": imageB64]],
                ]],
            ],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = bodyData
        guard let resp = httpJSON(req) else {
            dbg("api: http nil (timeout or empty)")
            return nil
        }
        guard let content = resp["content"] as? [[String: Any]] else {
            dbg("api: resp without content, keys=\(Array(resp.keys).sorted())")
            return nil
        }
        for block in content {
            if (block["type"] as? String) == "text",
               let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                dbg("api: ok: \(t.prefix(60))")
                return t.count > 120 ? String(t.prefix(120)) : t
            }
        }
        if (resp["stop_reason"] as? String) == "max_tokens" {
            dbg("api: truncated by max_tokens")
        } else {
            dbg("api: no text block found")
        }
        return nil
    }

    // 备选：本地 LM Studio（OpenAI 兼容、OpenAI 图片格式）
    private static func askLMStudio(system: String, userText: String, imageB64: String) -> String? {
        let base = "http://127.0.0.1:1234/v1"
        guard let models = httpJSON(URL(string: base + "/models")!, method: "GET", body: nil),
              let arr = models["data"] as? [[String: Any]] else { return nil }
        let ids = arr.compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { return nil }
        let prefer = ["qwen3.6", "muse", "glimmer", "-vl", "vision", "vl-"]
        let model = ids.first { id in
            let l = id.lowercased()
            return prefer.contains { l.contains($0) }
        } ?? ids[0]
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 200,
            "temperature": 0.7,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": [
                    ["type": "text", "text": userText],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64," + imageB64]],
                ]],
            ],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let resp = httpJSON(URL(string: base + "/chat/completions")!, method: "POST", body: bodyData),
              let choices = resp["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { return nil }
        let text = (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return nil }
        return text.count > 120 ? String(text.prefix(120)) : text
    }

    private static func dbg(_ s: String) {
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/roxy-peek.log") {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            try? line.write(toFile: "/tmp/roxy-peek.log", atomically: true, encoding: .utf8)
        }
    }

    private static func httpJSON(_ req: URLRequest) -> [String: Any]? {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data {
                result = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 250)
        return result
    }

    private static func httpJSON(_ url: URL, method: String, body: Data?) -> [String: Any]? {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 240
        if let b = body {
            req.httpBody = b
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data {
                result = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 250)
        return result
    }

    // ---------- 单击她：随机说一句本地台词（零 token 消耗）；吩咐任务走右键菜单「吩咐洛琪希…」----------
    func petClicked() {
        acknowledgeDesktopReturn()
        speakLocalLine()
        clickReaction()
    }

    // Shuffle a complete per-costume round so new clips cannot be starved by old reactions.
    private func nextClickAction() -> String {
        if lastClickAction == nil { lastClickAction = "wave"; return "wave" }
        if clickActionBag.isEmpty {
            clickActionBag = (["wave", "jump"] + extraClips.keys.sorted()).shuffled()
            if clickActionBag.first == lastClickAction,
               let index = clickActionBag.firstIndex(where: { $0 != lastClickAction }) {
                clickActionBag.swapAt(0, index)
            }
        }
        let next = clickActionBag.removeFirst()
        lastClickAction = next
        return next
    }

    private func clickReaction() {
        // Repeated fast clicks request one next animation instead of restarting frame zero.
        guard queuedClickKind == nil else { return }
        let next = nextClickAction()
        if (!ambientOnce && !onceKind.isEmpty) || !pendingOnce.isEmpty || chainedExtraKind != nil {
            queuedClickKind = next
        } else {
            beginOnce(next, repeats: 1)
        }
    }

    @objc private func askClaudeCode() {
        setPetHidden(false)
        if aiBusy {
            speak("我还在忙上一件事……请稍等一下哦。")
            return
        }
        let alert = NSAlert()
        alert.messageText = character.actionTitle
        alert.informativeText = "聊天直接输入即可（她当场回答，又快又省）；需要动手做的事，先勾选下方选项，再选这次交给哪个执行器。"
        alert.addButton(withTitle: "交给\(characterName)")
        alert.addButton(withTitle: "查看记录")
        alert.addButton(withTitle: "取消")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 96))
        let input = NSTextField(frame: NSRect(x: 0, y: 68, width: 360, height: 24))
        input.placeholderString = "在这里输入想说的话，或想让\(characterName)做的事…"
        let ccCheck = NSButton(checkboxWithTitle: "让她动手做（交给下面选中的执行器）", target: nil, action: nil)
        ccCheck.frame = NSRect(x: 0, y: 42, width: 360, height: 20)
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 10, width: 360, height: 26))
        let optionKeys: [(String, String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("opencode", "opencode"), ("dsh", "Harness")]
        var keys: [String] = []
        let currentHarness = PetController.currentHarness()
        var defaultIndex = -1
        for (key, title) in optionKeys where PetController.harnessPaths[key] != nil {
            pop.addItem(withTitle: title)
            keys.append(key)
            if key == currentHarness { defaultIndex = pop.numberOfItems - 1 }
        }
        if pop.numberOfItems == 0 {
            pop.addItem(withTitle: "（没有可用的执行器）")
            pop.isEnabled = false
        } else if defaultIndex >= 0 {
            pop.selectItem(at: defaultIndex)
        }
        box.addSubview(input)
        box.addSubview(ccCheck)
        box.addSubview(pop)
        alert.accessoryView = box
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeFirstResponder(input)
        let resp = alert.runModal()
        if resp == .alertSecondButtonReturn { showTaskHistory(); return }
        guard resp == .alertFirstButtonReturn else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let wantWork = ccCheck.state == .on && !keys.isEmpty
        let chosen = wantWork ? keys[min(pop.indexOfSelectedItem, keys.count - 1)] : nil
        runClaudeTask(text, ccMode: wantWork, harnessOverride: chosen)
    }

    /// 当前角色人设系统提示词（对话与任务共用，称呼跟随用户设置）
    private func characterPersonaSystem(_ extra: String) -> String {
        character.systemPrompt(owner: ownerTitle.isEmpty ? (character.isRoxy ? "您" : "你") : ownerTitle, extra: extra)
    }

    @objc private func pickHarness(_ sender: NSMenuItem) {
        let names = ["claude", "codex", "opencode", "dsh", "chat"]
        guard sender.tag >= 0 && sender.tag < names.count else { return }
        let h = names[sender.tag]
        UserDefaults.standard.set(h, forKey: "roxyHarness")
        statusItem?.menu = makeMenu(forStatusBar: true)
        let label: String
        switch h {
        case "claude": label = "Claude Code"
        case "codex": label = "Codex"
        case "opencode": label = "opencode"
        case "dsh": label = "Harness"
        default: label = "「仅对话」模式"
        }
        speak(h == "chat" ? "好，以后就只聊天，不动手了。" : "好，以后「动手做」就交给 \(label) 啦。")
    }

    private static func runCodex(prompt: String) -> String? {
        guard let bin = harnessPaths["codex"] else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // Codex 沙箱自治模式：workspace-write 沙箱 + 自动审批复核（不关闭沙箱）
        p.arguments = ["exec", "--json", "--skip-git-repo-check", "-s", "workspace-write", "--approve-for-me", "-C", NSHomeDirectory(), prompt]
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(300)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationReason == .exit && p.terminationStatus == 0 else { return nil }
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var finalText: String? = nil
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "thread.started", let tid = obj["thread_id"] as? String {
                UserDefaults.standard.set(tid, forKey: "roxyCodexThread")
            } else if type == "item.completed",
                      let item = obj["item"] as? [String: Any],
                      (item["type"] as? String) == "agent_message",
                      let t = item["text"] as? String, !t.isEmpty {
                finalText = t
            }
        }
        return finalText
    }

    private static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static func runOpencode(prompt: String, continueRoxy: Bool) -> String? {
        guard let bin = harnessPaths["opencode"] else { return nil }
        let d = UserDefaults.standard
        let started = continueRoxy && d.bool(forKey: "roxyOpencodeStarted")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = started ? ["run", "--auto", "--continue", prompt] : ["run", "--auto", prompt]
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(300)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationReason == .exit && p.terminationStatus == 0 else { return nil }
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let cleaned = stripANSI(raw).split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
        if continueRoxy && !started && !cleaned.isEmpty { d.set(true, forKey: "roxyOpencodeStarted") }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// DeepSeek Harness 无头模式：跑一次任务，打印最终答复后退出。
    private static func runDsh(prompt: String) -> String? {
        guard let bin = harnessPaths["dsh"] else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--profile", "headless", prompt]
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(300)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationReason == .exit && p.terminationStatus == 0 else { return nil }
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let cleaned = stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func runClaudeTask(_ text: String, ccMode: Bool, harnessOverride: String? = nil) {
        let harness = harnessOverride ?? PetController.currentHarness()
        let chatMode = !ccMode || harness == "chat"
        if chatMode && !PetController.hasAPIConfig() {
            speak("唔……我还没连上「那边的世界」呢。先帮我配置一下 API，再找我一次就好哦。")
            promptForAPISettings()
            return
        }
        aiBusy = true
        directWorkTiming = chatMode ? nil : DirectWorkTiming(startedAt: CACurrentMediaTime(), costumeID: character.id)
        speak(chatMode ? "嗯，我听着呢。" : "嗯……交给我吧。", seconds: 6)
        appendHistory(role: "user", text: text)
        if chatMode {
            // 纯对话：直连配置好的 API 当场回答，不惊动 Claude Code
            let sys = characterPersonaSystem("这是主人发来的一段话，请自然地回应（1~5 句，可用 Markdown 排版），像平时聊天一样。")
            DispatchQueue.global().async { [weak self] in
                let r = PetController.askTextAPI(system: sys, userText: text)
                DispatchQueue.main.async { self?.deliverTaskResult(r, sid: nil) }
            }
            return
        }
        let fullPrompt = characterPersonaSystem("任务请照常执行、事实照常核实，但**最终回答要用\(characterName)的口吻来写**，保留全部结论与细节的准确性，可以用 Markdown 排版。\n\n【任务】\(text)")
        if harness == "codex" {
            DispatchQueue.global().async { [weak self] in
                let r = PetController.runCodex(prompt: fullPrompt)
                DispatchQueue.main.async { self?.deliverTaskResult(r, sid: nil) }
            }
            return
        }
        if harness == "opencode" {
            let continueRoxy = character.isRoxy
            DispatchQueue.global().async { [weak self] in
                let r = PetController.runOpencode(prompt: fullPrompt, continueRoxy: continueRoxy)
                DispatchQueue.main.async { self?.deliverTaskResult(r, sid: nil) }
            }
            return
        }
        if harness == "dsh" {
            DispatchQueue.global().async { [weak self] in
                let r = PetController.runDsh(prompt: fullPrompt)
                DispatchQueue.main.async { self?.deliverTaskResult(r, sid: nil) }
            }
            return
        }
        let d = UserDefaults.standard
        let key = character.isRoxy ? "roxySessionId" : "petSessionId." + character.characterID
        let sid: String
        let isFirst: Bool
        if let s = d.string(forKey: key) {
            sid = s
            isFirst = false
        } else {
            sid = UUID().uuidString.lowercased()
            d.set(sid, forKey: key)
            isFirst = true
        }
        DispatchQueue.global().async { [weak self] in
            let result = PetController.runClaude(prompt: fullPrompt, sessionId: sid, isFirst: isFirst)
            DispatchQueue.main.async { self?.deliverTaskResult(result, sid: sid) }
        }
    }

    private func deliverTaskResult(_ line: String?, sid: String?) {
        let successful = !(line?.isEmpty ?? true)
        let workDuration = takeDirectWorkDuration(successful: successful)
        aiBusy = false
        if let line = line, !line.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(line, forType: .string)
            appendHistory(role: "roxy", text: line)
            let summary = line.count > 110 ? String(line.prefix(110)) + "…（点击气泡可复制全文 / 接续会话）" : line
            speak(summary, seconds: 25, fullText: line, resumeSid: sid)
            appendReplyExtraAction(workDuration: workDuration)
        } else {
            let fail = randomOf(lines("ai_fail", AI_FAIL))
            appendHistory(role: "roxy", text: "（\(fail)）")
            speak(fail)
        }
    }

    private func takeDirectWorkDuration(successful: Bool, at now: CFTimeInterval = CACurrentMediaTime()) -> Double? {
        defer { directWorkTiming = nil }
        return directWorkTiming?.duration(for: character.id, at: now, successful: successful)
    }

    // ---------- DeepSeek 余额 ----------
    /// 查官方余额（GET /user/balance）。回调在后台线程，调用方自行切主线程。
    /// - Returns: (展示文案, 总额数值-仅当能解析)
    private static func fetchDeepSeekBalance(completion: @escaping (String?, Double?) -> Void) {
        guard let (_, key, _) = PetController.apiConfig() else {
            completion("还没配置 API，查不了 DeepSeek 余额哦。", nil)
            return
        }
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, _, err in
            var text = "DeepSeek 余额查询失败，稍后再试试吧。"
            var total: Double?
            if err == nil, let data = data,
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let infos = obj["balance_infos"] as? [[String: Any]] ?? []
                let parts: [String] = infos.compactMap { info in
                    let cur = (info["currency"] as? String) ?? ""
                    let sym = cur == "CNY" ? "¥" : (cur == "USD" ? "$" : cur + " ")
                    guard let totalStr = info["total_balance"] as? String else { return nil }
                    if total == nil { total = Double(totalStr) }
                    let granted = (info["granted_balance"] as? String) ?? "0"
                    let topped = (info["topped_up_balance"] as? String) ?? "0"
                    return "\(sym)\(totalStr)（赠送 \(sym)\(granted)、充值 \(sym)\(topped)）"
                }
                if !parts.isEmpty {
                    text = "DeepSeek 余额：" + parts.joined(separator: "；")
                } else if let available = obj["is_available"] as? Bool, !available {
                    text = "DeepSeek 余额不可用：可能余额不足或 Key 无效。"
                }
            }
            completion(text, total)
        }.resume()
    }

    @objc private func queryDeepSeekBalance() {
        guard PetController.apiConfig() != nil else {
            speak("还没配置 API，查不了余额哦。")
            promptForAPISettings()
            return
        }
        speak("我去看看账上还剩多少……", seconds: 4)
        PetController.fetchDeepSeekBalance { [weak self] text, total in
            DispatchQueue.main.async {
                guard let self else { return }
                self.speak(text ?? "DeepSeek 余额查询失败，稍后再试试吧。")
                if let total { self.dshBalanceTotal = total }
                if let text { self.dshBalanceText = text }
                self.refreshDshStatusLine()
            }
        }
    }

    // ---------- AI 点选发言（默认不用；点选才消耗大模型额度）----------
    @objc private func askAI() {
        setPetHidden(false)
        if aiBusy { return }
        guard PetController.hasAPIConfig() else {
            speak("唔……说话前得先连上「那边的世界」——帮我配置一下 API 好吗？")
            promptForAPISettings()
            return
        }
        aiBusy = true
        speak(randomOf(lines("ai_thinking", AI_THINKING)), seconds: 8)
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        let timeStr = df.string(from: Date())
        let prompt = characterPersonaSystem("请用角色口吻说一句简短问候或闲话（10~40 字）。现在是 \(timeStr)。只输出台词本身，不要引号或解释。")
        DispatchQueue.global().async { [weak self] in
            var result = PetController.askTextAPI(system: prompt, userText: "请说一句。")
            if let r = result, let first = r.split(separator: "\n").first { result = String(first) }
            DispatchQueue.main.async {
                self?.aiBusy = false
                if let line = result, !line.isEmpty {
                    self?.speak(line)
                } else {
                    self?.speak(randomOf(self?.lines("ai_fail", AI_FAIL) ?? []))
                }
            }
        }
    }

    // ---------- 任务执行器（可切换的 harness）----------
    private static var harnessPaths: [String: String] = [:]

    /// 用 zsh 找命令（最多等 2 秒，避免交互 shell 卡住启动）。
    private static func shellLookup(_ name: String, interactive: Bool) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [interactive ? "-ilc" : "-lc", "command -v " + name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 交互 shell 可能先打印提示，最后一行才是路径
        let candidate = s.split(separator: "\n").last.map(String.init) ?? s
        if !candidate.isEmpty && FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        return nil
    }

    /// 自动探测本机命令（每台机器路径都可能不同，不写死任何一台的环境）。
    private static func findBinary(_ name: String) -> String? {
        // 1) 登录 shell（.zprofile / .zshenv）
        if let found = shellLookup(name, interactive: false) { return found }
        // 2) 登录 + 交互 shell：很多人的 PATH 写在 .zshrc 里，GUI 启动的 app 读不到
        if let found = shellLookup(name, interactive: true) { return found }
        // 3) 常见安装位置兜底（npm -g / homebrew / bun / cargo / asdf / volta / pnpm 等）
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/" + name,
            "/usr/local/bin/" + name,
            home + "/.local/bin/" + name,
            home + "/.bun/bin/" + name,
            home + "/.opencode/bin/" + name,
            home + "/.cargo/bin/" + name,
            home + "/.volta/bin/" + name,
            home + "/.asdf/shims/" + name,
            home + "/.npm-global/bin/" + name,
            home + "/.local/share/pnpm/" + name,
            "/usr/bin/" + name,
            "/bin/" + name,
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    /// 每次启动 / 打开设置 / 定期重新探测所有 CLI。
    static func detectHarnesses() {
        for h in ["claude", "codex", "opencode", "dsh"] {
            if let p = findBinary(h) { harnessPaths[h] = p }
        }
    }

    private static func processRunning(match: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", match]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func currentHarness() -> String {
        let h = UserDefaults.standard.string(forKey: "roxyHarness") ?? "claude"
        if h == "chat" { return "chat" }
        if harnessPaths[h] != nil { return h }
        if harnessPaths["claude"] != nil { return "claude" }
        return harnessPaths.keys.sorted().first ?? "chat"
    }

    private static func promptTitle() -> String {
        let t = UserDefaults.standard.string(forKey: "roxyOwnerTitle") ?? ""
        return t.isEmpty ? "您" : t
    }

    private static func findClaude() -> String? { findBinary("claude") }

    private static func runClaude(prompt: String, sessionId: String? = nil, isFirst: Bool = false) -> String? {
        guard let path = findClaude() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        if let sid = sessionId {
            p.arguments = isFirst ? ["-p", "--dangerously-skip-permissions", "--session-id", sid, prompt] : ["-p", "--dangerously-skip-permissions", "--resume", sid, prompt]
        } else {
            p.arguments = ["-p", prompt]
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(300)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning {
            p.terminate()
            return nil
        }
        guard p.terminationReason == .exit && p.terminationStatus == 0 else { return nil }
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // 过滤 CLI 诊断行（如 [claude-code:unrecognized_model] …），保留完整正文
        let valid = raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[claude-code") }
        let text = valid.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    // ---------- 显示 ----------
    private func show(row: Int, col: Int) {
        if currentSheetKey == "base" && row == currentRow && col == currentCol { return }
        currentSheetKey = "base"
        currentRow = row
        currentCol = col
        currentImage = frames[row][col]
        petView?.needsDisplay = true
    }

    private func showExtra(_ clip: ExtraClip, col: Int) {
        guard clip.frames.indices.contains(col) else { return }
        let key = "extra:" + character.id + ":" + clip.description.id
        if currentSheetKey == key && currentCol == col { return }
        currentSheetKey = key
        currentRow = clip.description.row
        currentCol = col
        currentImage = clip.frames[col]
        petView?.needsDisplay = true
    }

    // 交互判定（点击穿透 / 悬停）：用稳定的"站姿轮廓"
    func isOpaquePixel(viewPoint p: NSPoint) -> Bool {
        guard let v = petView, !hoverMask.isEmpty else { return false }
        let w = v.bounds.width, h = v.bounds.height
        guard w > 0, h > 0 else { return false }
        let px = Int(p.x / w * CGFloat(CELL_W))
        let pyTop = Int((1 - p.y / h) * CGFloat(CELL_H))
        guard px >= 0, px < CELL_W, pyTop >= 0, pyTop < CELL_H else { return false }
        return hoverMask[pyTop * CELL_W + px] > 24
    }

    // ---------- 称呼设置 ----------
    private func resolvedTitle(_ s: String) -> String {
        guard s.contains("{称呼}") else { return s }
        if !ownerTitle.isEmpty { return s.replacingOccurrences(of: "{称呼}", with: ownerTitle) }
        var t = s
        for pat in ["，{称呼}", "{称呼}，", "！{称呼}", "{称呼}！"] {
            t = t.replacingOccurrences(of: pat, with: "")
        }
        t = t.replacingOccurrences(of: "{称呼}的", with: "您的")
        t = t.replacingOccurrences(of: "{称呼}", with: "")
        return t
    }

    @objc private func showTitleSettings() { promptForTitle(firstRun: false) }

    @objc private func showAPISettings() { promptForAPISettings() }

    private func promptForAPISettings() {
        setPetHidden(false)
        let d = UserDefaults.standard
        var detected = "未检测到可用配置，请在下方填写"
        if let cfg = PetController.apiConfig() {
            detected = (cfg.base.host ?? cfg.base.absoluteString) + " · " + cfg.model
            if (d.string(forKey: "roxyApiBase") ?? "").isEmpty && (d.string(forKey: "roxyApiKey") ?? "").isEmpty {
                detected += "（自动沿用 Claude Code 配置，无需填写）"
            }
        }
        let alert = NSAlert()
        alert.messageText = "API 设置"
        alert.informativeText = "「聊天 / 想句话 / 看屏幕」需要一个 Anthropic 兼容的 API。\n当前生效：\(detected)\n三项都留空则自动沿用 ~/.claude/settings.json 里的 Claude Code 配置。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 112))
        let fBase = NSTextField(frame: NSRect(x: 0, y: 82, width: 400, height: 24))
        fBase.placeholderString = "接口地址 例如 https://api.anthropic.com 或 https://api.deepseek.com/anthropic"
        let fKey = NSSecureTextField(frame: NSRect(x: 0, y: 43, width: 400, height: 24))
        fKey.placeholderString = "API Key（sk-…）"
        let fModel = NSComboBox(frame: NSRect(x: 0, y: 4, width: 400, height: 24))
        fModel.addItems(withObjectValues: ["deepseek-flash", "deepseek-chat", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"])
        fModel.isEditable = true
        fModel.placeholderString = "模型名（可直接输入，或点下拉选择）"
        fBase.stringValue = d.string(forKey: "roxyApiBase") ?? ""
        fKey.stringValue = d.string(forKey: "roxyApiKey") ?? ""
        fModel.stringValue = d.string(forKey: "roxyApiModel") ?? ""
        box.addSubview(fBase)
        box.addSubview(fKey)
        box.addSubview(fModel)
        alert.accessoryView = box
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeFirstResponder(fBase)
        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }
        d.set(fBase.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "roxyApiBase")
        d.set(fKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "roxyApiKey")
        d.set(fModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "roxyApiModel")
        speak(PetController.hasAPIConfig() ? "好啦，连上「那边的世界」了，随时可以找我说话。" : "唔……好像还差点什么，请再检查一下设置哦。")
    }

    private func promptForTitle(firstRun: Bool) {
        setPetHidden(false)
        let alert = NSAlert()
        alert.messageText = firstRun ? "初次见面，我是\(characterName)" : "称呼设置"
        alert.informativeText = "平时我该怎么称呼您呢？（留空则用「您」）"
        alert.addButton(withTitle: "就这么叫")
        alert.addButton(withTitle: firstRun ? "先用「您」" : "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "例如：主人 / 老板 / 亲爱的"
        input.stringValue = ownerTitle
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeFirstResponder(input)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            ownerTitle = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(ownerTitle, forKey: "roxyOwnerTitle")
            speak(ownerTitle.isEmpty ? "好的，那我以后就用「您」来称呼您。" : "好的，以后我就叫您「\(ownerTitle)」啦。")
        } else if firstRun {
            ownerTitle = ""
            UserDefaults.standard.set("", forKey: "roxyOwnerTitle")
        }
    }

    // ---------- 统一设置窗口（称呼 / API / 任务执行器）----------
    private var settingsWindow: NSWindow?
    private var swTitleField: NSTextField?
    private var swBaseField: NSTextField?
    private var swKeyField: NSSecureTextField?
    private var swModelBox: NSComboBox?
    private var swHarnessRadios: [NSButton] = []
    private var swWatchBoxes: [NSButton] = []
    private var swStatusLabel: NSTextField?
    // DeepSeek Harness 分组
    private var swDshStatusLabel: NSTextField?
    private var swDshWatchBox: NSButton?
    private var swDshConvBox: NSButton?
    private var swDshLiveBox: NSButton?
    /// 未连接时隐藏的 Harness 明细行（只留状态 + 重新检测）
    private var swDshExtraViews: [NSView] = []
    private var settingsSaveClicked = false

    @objc private func showSettingsWindow() {
        setPetHidden(false)
        if settingsWindow == nil { buildSettingsWindow() }
        settingsSaveClicked = false
        refreshHarnessDetection()
        refreshSettingsFields()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildSettingsWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 820),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(characterName) · 设置"
        w.isReleasedWhenClosed = false

        func groupTitle(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = NSFont.boldSystemFont(ofSize: 12)
            return l
        }
        func separatorLine() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            box.widthAnchor.constraint(equalToConstant: 560).isActive = true
            return box
        }
        func vstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
            let st = NSStackView(views: views)
            st.orientation = .vertical
            st.alignment = .leading
            st.spacing = spacing
            return st
        }

        // ---- 对话 ----
        let fTitle = NSTextField(string: "")
        fTitle.placeholderString = "她怎么称呼您（留空则用「您」）"
        let fBase = NSTextField(string: "")
        fBase.placeholderString = "如 https://api.deepseek.com/anthropic"
        let fKey = NSSecureTextField(string: "")
        fKey.placeholderString = "留空则沿用 Claude Code 的配置"
        let mBox = NSComboBox(string: "")
        mBox.addItems(withObjectValues: ["deepseek-flash", "deepseek-chat", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"])
        mBox.isEditable = true
        mBox.placeholderString = "模型名（可选，点下拉可挑）"
        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        for v in [fTitle, fBase, fKey, mBox] as [NSView] {
            v.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        let chatGrid = NSGridView(views: [
            [NSTextField(labelWithString: "称呼"), fTitle],
            [NSTextField(labelWithString: "API 接口地址"), fBase],
            [NSTextField(labelWithString: "API Key"), fKey],
            [NSTextField(labelWithString: "模型"), mBox],
            [NSGridCell.emptyContentView, status],
        ])
        chatGrid.rowAlignment = .firstBaseline
        chatGrid.column(at: 0).xPlacement = .trailing
        chatGrid.column(at: 1).xPlacement = .leading
        chatGrid.columnSpacing = 12
        chatGrid.rowSpacing = 8

        // ---- DeepSeek Harness ----
        let dshStatus = NSTextField(labelWithString: "")
        dshStatus.font = NSFont.systemFont(ofSize: 11)
        dshStatus.textColor = .secondaryLabelColor
        dshStatus.lineBreakMode = .byWordWrapping
        dshStatus.maximumNumberOfLines = 3
        dshStatus.preferredMaxLayoutWidth = 520
        dshStatus.widthAnchor.constraint(equalToConstant: 520).isActive = true
        let recheck = NSButton(title: "重新检测", target: self, action: #selector(redetectDsh))
        recheck.bezelStyle = .rounded
        let queryBtn = NSButton(title: "查询 DeepSeek 余额", target: self, action: #selector(queryDeepSeekBalance))
        queryBtn.bezelStyle = .rounded
        let dshButtons = NSStackView(views: [recheck, queryBtn])
        dshButtons.orientation = .horizontal
        dshButtons.spacing = 8
        let dshWatch = NSButton(checkboxWithTitle: "状态联动：干活跑动 · 完工挥手 · 权限批准", target: nil, action: nil)
        let dshConv = NSButton(checkboxWithTitle: "对话同步：把双向对话显示在「记录」里", target: nil, action: nil)
        let dshLive = NSButton(checkboxWithTitle: "实时显示 DeepSeek 余额：每 60 秒刷新，完工时显示本轮花费", target: nil, action: nil)
        let dshHint = NSTextField(labelWithString: "需要在 Harness 里安装 04-integration/dsh-plugin（dsh-plugin-roxy）")
        dshHint.font = NSFont.systemFont(ofSize: 11)
        dshHint.textColor = .tertiaryLabelColor
        let dshToggles = vstack([dshWatch, dshConv, dshLive], spacing: 4)

        // ---- 任务执行器 ----
        let hDefs: [(String, String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("opencode", "opencode"), ("dsh", "Harness"), ("chat", "仅对话（不执行命令）")]
        var radios: [NSButton] = []
        for (i, hd) in hDefs.enumerated() {
            let missing = (hd.0 != "chat" && PetController.harnessPaths[hd.0] == nil)
            let title = missing ? hd.1 + "（未安装）" : (hd.0 == "chat" ? hd.1 : hd.1 + " ✓ 已检测到")
            let rb = NSButton(radioButtonWithTitle: title, target: self, action: #selector(harnessRadioChanged(_:)))
            rb.tag = i
            rb.isEnabled = !missing
            radios.append(rb)
        }
        let radioStack = vstack(radios, spacing: 5)

        // ---- 状态联动（其它 CLI）----
        let watchDefs: [(String, String)] = [("claude", "Claude Code —— 干活跑动 · 完工挥手 · 等待提醒"), ("codex", "Codex —— 完工挥手（含回复转述）"), ("opencode", "opencode —— 进程检测：运行中跑动 · 结束挥手")]
        var watches: [NSButton] = []
        for (i, wd) in watchDefs.enumerated() {
            let cb = NSButton(checkboxWithTitle: wd.1, target: nil, action: nil)
            cb.tag = i
            watches.append(cb)
        }
        let watchStack = vstack(watches, spacing: 4)
        let watchNote = NSTextField(labelWithString: "可多选：勾上哪家，她就在哪家干活时有反应")
        watchNote.font = NSFont.systemFont(ofSize: 11)
        watchNote.textColor = .secondaryLabelColor

        let saveBtn = NSButton(title: "保存并应用", target: self, action: #selector(saveSettingsWindow))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closeSettingsWindow))
        closeBtn.bezelStyle = .rounded
        let btns = NSStackView(views: [saveBtn, closeBtn])
        btns.orientation = .horizontal
        btns.spacing = 10

        let root = vstack([
            groupTitle("对话"), chatGrid, separatorLine(),
            groupTitle("Harness"), dshStatus, dshButtons, dshToggles, dshHint, separatorLine(),
            groupTitle("任务执行器"), radioStack, separatorLine(),
            groupTitle("状态联动"), watchStack, watchNote, btns,
        ], spacing: 8)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 820))
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        w.contentView = content
        w.center()
        settingsWindow = w
        swTitleField = fTitle
        swBaseField = fBase
        swKeyField = fKey
        swModelBox = mBox
        swHarnessRadios = radios
        swWatchBoxes = watches
        swStatusLabel = status
        swDshStatusLabel = dshStatus
        swDshWatchBox = dshWatch
        swDshConvBox = dshConv
        swDshLiveBox = dshLive
        swDshExtraViews = [queryBtn, dshToggles, dshHint]
        refreshDshStatusLine()
    }

    private func refreshSettingsFields() {
        let d = UserDefaults.standard
        swTitleField?.stringValue = ownerTitle
        swBaseField?.stringValue = d.string(forKey: "roxyApiBase") ?? ""
        swKeyField?.stringValue = d.string(forKey: "roxyApiKey") ?? ""
        swModelBox?.stringValue = d.string(forKey: "roxyApiModel") ?? ""
        let names = ["claude", "codex", "opencode", "dsh", "chat"]
        let cur = PetController.currentHarness()
        if let idx = names.firstIndex(of: cur) {
            for (i, rb) in swHarnessRadios.enumerated() { rb.state = (i == idx) ? .on : .off }
        }
        let watchKeys = ["roxyWatchClaude", "roxyWatchCodex", "roxyWatchOpencode"]
        let watchDefaults = [true, false, false]
        for (i, cb) in swWatchBoxes.enumerated() {
            let on = d.object(forKey: watchKeys[i]) == nil ? watchDefaults[i] : d.bool(forKey: watchKeys[i])
            cb.state = on ? .on : .off
        }
        let dshWatchOn = d.object(forKey: "roxyWatchDsh") == nil ? true : d.bool(forKey: "roxyWatchDsh")
        swDshWatchBox?.state = dshWatchOn ? .on : .off
        let dshConvOn = d.object(forKey: "roxyDshConversation") == nil ? true : d.bool(forKey: "roxyDshConversation")
        swDshConvBox?.state = dshConvOn ? .on : .off
        let dshLiveOn = d.object(forKey: "roxyDshBalanceLive") == nil ? true : d.bool(forKey: "roxyDshBalanceLive")
        swDshLiveBox?.state = dshLiveOn ? .on : .off
        refreshDshStatusLine()
        if let cfg = PetController.apiConfig() {
            var line = "当前生效：\(cfg.base.host ?? cfg.base.absoluteString) · \(cfg.model)"
            if (d.string(forKey: "roxyApiBase") ?? "").isEmpty && (d.string(forKey: "roxyApiKey") ?? "").isEmpty {
                line += "（自动沿用 Claude Code 配置）"
            }
            swStatusLabel?.stringValue = line
        } else {
            swStatusLabel?.stringValue = "尚未配置 API——聊天 / 想句话 / 看屏幕需要它"
        }
    }

    private func settingsUnchanged() -> Bool {
        let d = UserDefaults.standard
        func tv(_ f: NSTextField?) -> String { (f?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if tv(swTitleField) != (d.string(forKey: "roxyOwnerTitle") ?? "") { return false }
        if tv(swBaseField) != (d.string(forKey: "roxyApiBase") ?? "") { return false }
        if tv(swKeyField) != (d.string(forKey: "roxyApiKey") ?? "") { return false }
        if tv(swModelBox) != (d.string(forKey: "roxyApiModel") ?? "") { return false }
        let names = ["claude", "codex", "opencode", "dsh", "chat"]
        if let on = swHarnessRadios.first(where: { $0.state == .on }),
           names[on.tag] != (d.string(forKey: "roxyHarness") ?? "claude") {
            return false
        }
        let watchKeys = ["roxyWatchClaude", "roxyWatchCodex", "roxyWatchOpencode"]
        let watchDefaults = [true, false, false]
        for (i, cb) in swWatchBoxes.enumerated() {
            let cur = d.object(forKey: watchKeys[i]) == nil ? watchDefaults[i] : d.bool(forKey: watchKeys[i])
            if (cb.state == .on) != cur { return false }
        }
        func unchanged(_ box: NSButton?, _ key: String, _ def: Bool) -> Bool {
            let cur = d.object(forKey: key) == nil ? def : d.bool(forKey: key)
            return (box?.state == .on) == cur
        }
        if !unchanged(swDshWatchBox, "roxyWatchDsh", true) { return false }
        if !unchanged(swDshConvBox, "roxyDshConversation", true) { return false }
        if !unchanged(swDshLiveBox, "roxyDshBalanceLive", true) { return false }
        return true
    }

    @objc private func saveSettingsWindow() {
        // 第一次点击 = 保存；之后每次点击 = 关闭
        if settingsSaveClicked {
            settingsWindow?.orderOut(nil)
            return
        }
        settingsSaveClicked = true
        if settingsUnchanged() {
            speak("设置没有变动哦。")
            return
        }
        let d = UserDefaults.standard
        ownerTitle = (swTitleField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        d.set(ownerTitle, forKey: "roxyOwnerTitle")
        d.set((swBaseField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines), forKey: "roxyApiBase")
        d.set((swKeyField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines), forKey: "roxyApiKey")
        d.set((swModelBox?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines), forKey: "roxyApiModel")
        let names = ["claude", "codex", "opencode", "dsh", "chat"]
        if let on = swHarnessRadios.first(where: { $0.state == .on }) {
            d.set(names[on.tag], forKey: "roxyHarness")
        }
        let watchKeys = ["roxyWatchClaude", "roxyWatchCodex", "roxyWatchOpencode"]
        for (i, cb) in swWatchBoxes.enumerated() {
            d.set(cb.state == .on, forKey: watchKeys[i])
        }
        d.set(swDshWatchBox?.state == .on, forKey: "roxyWatchDsh")
        d.set(swDshConvBox?.state == .on, forKey: "roxyDshConversation")
        d.set(swDshLiveBox?.state == .on, forKey: "roxyDshBalanceLive")
        statusItem?.menu = makeMenu(forStatusBar: true)
        refreshSettingsFields()
        speak("设置保存好啦。")
    }

    @objc private func toggleDshConversation() {
        let d = UserDefaults.standard
        let cur = d.object(forKey: "roxyDshConversation") == nil ? true : d.bool(forKey: "roxyDshConversation")
        d.set(!cur, forKey: "roxyDshConversation")
        refreshHistoryWindow()
        refreshSettingsFields()
        statusItem?.menu = makeMenu(forStatusBar: true)
        speak(!cur ? "好，对话会同步进记录了。" : "好，记录里先不显示 Harness 的对话了。", seconds: 5)
    }

    @objc private func toggleDshBalanceLive() {
        let d = UserDefaults.standard
        let cur = d.object(forKey: "roxyDshBalanceLive") == nil ? true : d.bool(forKey: "roxyDshBalanceLive")
        d.set(!cur, forKey: "roxyDshBalanceLive")
        refreshSettingsFields()
        statusItem?.menu = makeMenu(forStatusBar: true)
        speak(!cur ? "好，余额每 60 秒刷新一次。" : "好，实时余额关掉了，需要时点「刷新余额」。", seconds: 5)
    }

    @objc private func harnessRadioChanged(_ sender: NSButton) {
        // 手动互斥（不依赖 AppKit 的自动分组规则，任何布局下都可靠）
        for rb in swHarnessRadios { rb.state = (rb === sender) ? .on : .off }
    }

    /// 重新探测所有 CLI，并刷新设置里的标题、Harness 状态与菜单。
    private func refreshHarnessDetection(announce: Bool = false) {
        PetController.detectHarnesses()
        let names = ["claude", "codex", "opencode", "dsh"]
        let titles = ["Claude Code", "Codex", "opencode", "Harness"]
        for (i, rb) in swHarnessRadios.enumerated() where i < titles.count {
            let missing = (PetController.harnessPaths[names[i]] == nil)
            rb.title = missing ? titles[i] + "（未安装）" : titles[i] + " ✓ 已检测到"
            rb.isEnabled = !missing
        }
        refreshDshStatusLine()
        statusItem?.menu = makeMenu(forStatusBar: true)
        if announce {
            if let path = PetController.harnessPaths["dsh"] {
                speak("找到 Harness 啦：" + path, seconds: 6)
            } else {
                speak("没检测到 Harness，装好后我会自动再找。", seconds: 8)
            }
        }
    }

    /// 设置里点「重新检测」
    @objc private func redetectDsh() {
        refreshHarnessDetection(announce: true)
    }

    @objc private func closeSettingsWindow() { settingsWindow?.orderOut(nil) }


    // ---------- 菜单栏图标：从当前角色自己的图集里裁出头部 ----------
    // 任何角色都自动适用，不需要额外的图标素材。
    private func makeStatusIcon(from frames: [[NSImage]]) -> NSImage? {
        guard let src = frames.first?.first,
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let w = cg.width, h = cg.height
        let bpr = cg.bytesPerRow, bpp = max(1, cg.bitsPerPixel / 8)
        // 1) 找不透明像素的外接框（隔行采样即可）
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let a = ptr[y * bpr + x * bpp + (bpp - 1)]
                if a > 24 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        // 2) 取人物上方「头肩」部分，横向居中裁成正方形
        let boxW = CGFloat(maxX - minX + 1), boxH = CGFloat(maxY - minY + 1)
        let side = min(boxW, boxH * 0.62)
        let cx = CGFloat(minX) + boxW / 2
        let x0 = max(0, min(CGFloat(w) - side, cx - side / 2))
        let rect = CGRect(x: x0, y: CGFloat(minY), width: side, height: side)
        guard side > 8, let cropped = cg.cropping(to: rect) else { return nil }
        let img = NSImage(cgImage: cropped, size: NSSize(width: 18, height: 18))
        img.isTemplate = false          // 保留角色配色，不走系统单色模板
        return img
    }

    private func refreshStatusIcon() {
        let fallback = NSImage(named: NSImage.applicationIconName)
        fallback?.size = NSSize(width: 18, height: 18)
        statusItem?.button?.image = makeStatusIcon(from: frames) ?? fallback
    }

    // ---------- 隐身 / 菜单栏图标 ----------
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            let fallback = NSImage(named: NSImage.applicationIconName)
            fallback?.size = NSSize(width: 18, height: 18)
            btn.image = makeStatusIcon(from: frames) ?? fallback
            btn.toolTip = "\(character.menuTitle) · Roxy"
        }
        item.menu = makeMenu(forStatusBar: true)
        statusItem = item
    }

    @objc private func togglePetVisibility() { setPetHidden(!petHidden) }

    private func setPetHidden(_ hidden: Bool) {
        petHidden = hidden
        if hidden {
            bubbleVisible = false
            bubbleWindow?.orderOut(nil)
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
        statusVisibilityItem?.title = hidden ? "显示\(characterName)" : "隐藏\(characterName)"
    }

    private func makeMenu(forStatusBar: Bool) -> NSMenu {
        let menu = NSMenu()
        let picker = NSMenuItem(title: "角色 · \(character.menuTitle)", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        // Group by identity, including custom costumes from separate folders.
        var groups: [[PetCharacter]] = []
        for profile in characters {
            if let index = groups.firstIndex(where: { $0.first?.characterID == profile.characterID }) {
                groups[index].append(profile)
            } else {
                groups.append([profile])
            }
        }
        for (index, group) in groups.enumerated() {
            if index > 0 { choices.addItem(.separator()) }
            for profile in group {
                let item = NSMenuItem(title: profile.menuTitle, action: #selector(selectCharacter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                item.state = profile.id == character.id ? .on : .off
                item.isEnabled = !aiBusy
                choices.addItem(item)
            }
        }
        choices.addItem(.separator())
        let add = NSMenuItem(title: "添加其他角色…", action: #selector(openCharactersFolder), keyEquivalent: "")
        add.target = self
        choices.addItem(add)
        let reload = NSMenuItem(title: "重新载入角色与语料", action: #selector(reloadCharacters), keyEquivalent: "")
        reload.target = self
        reload.isEnabled = !aiBusy
        choices.addItem(reload)
        if aiBusy { choices.addItem(NSMenuItem(title: "回复完成后可切换角色", action: nil, keyEquivalent: "")) }
        picker.submenu = choices
        menu.addItem(picker)
        menu.addItem(.separator())
        let viz = NSMenuItem(title: petHidden ? "显示\(characterName)" : "隐藏\(characterName)", action: #selector(togglePetVisibility), keyEquivalent: "")
        viz.target = self
        if forStatusBar {
            menu.addItem(viz)
            statusVisibilityItem = viz
            menu.addItem(.separator())
        }
        let say = NSMenuItem(title: "说句话（本地台词）", action: #selector(sayLocal), keyEquivalent: "")
        say.target = self
        menu.addItem(say)
        let ai = NSMenuItem(title: "说句话（大模型）", action: #selector(askAI), keyEquivalent: "")
        ai.target = self
        menu.addItem(ai)
        menu.addItem(.separator())
        let task = NSMenuItem(title: "\(character.actionTitle)（聊天 / 做事）", action: #selector(askClaudeCode), keyEquivalent: "")
        task.target = self
        menu.addItem(task)
        let look = NSMenuItem(title: character.screenTitle, action: #selector(lookAtScreen), keyEquivalent: "")
        look.target = self
        menu.addItem(look)
        menu.addItem(.separator())
        let hist = NSMenuItem(title: "查看\(character.historyTitle)", action: #selector(showTaskHistory), keyEquivalent: "")
        hist.target = self
        menu.addItem(hist)
        let reset = NSMenuItem(title: "回到屏幕右下角", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        // DeepSeek Harness 相关操作统一收进一个子菜单：
        // 连接状态 / 余额 / 刷新余额 / 对话同步 / 实时余额 / 连接设置。
        if PetController.isDshConnected() {
            let d = UserDefaults.standard
            let dshItem = NSMenuItem(title: "DeepSeek Harness", action: nil, keyEquivalent: "")
            let dshMenu = NSMenu()
            let conn = NSMenuItem(title: "连接：已连接", action: nil, keyEquivalent: "")
            conn.isEnabled = false
            dshMenu.addItem(conn)
            let balance = NSMenuItem(title: dshBalanceTotal.map { String(format: "余额：¥%.2f", $0) } ?? "余额：未查询",
                                     action: nil, keyEquivalent: "")
            balance.isEnabled = false
            dshMenu.addItem(balance)
            let refresh = NSMenuItem(title: "刷新余额", action: #selector(queryDeepSeekBalance), keyEquivalent: "")
            refresh.target = self
            dshMenu.addItem(refresh)
            dshMenu.addItem(.separator())
            let convOn = d.object(forKey: "roxyDshConversation") == nil ? true : d.bool(forKey: "roxyDshConversation")
            let conv = NSMenuItem(title: "对话同步", action: #selector(toggleDshConversation), keyEquivalent: "")
            conv.target = self
            conv.state = convOn ? .on : .off
            dshMenu.addItem(conv)
            let liveOn = d.object(forKey: "roxyDshBalanceLive") == nil ? true : d.bool(forKey: "roxyDshBalanceLive")
            let live = NSMenuItem(title: "实时余额", action: #selector(toggleDshBalanceLive), keyEquivalent: "")
            live.target = self
            live.state = liveOn ? .on : .off
            dshMenu.addItem(live)
            dshMenu.addItem(.separator())
            let settingsItem = NSMenuItem(title: "连接设置…", action: #selector(showSettingsWindow), keyEquivalent: "")
            settingsItem.target = self
            dshMenu.addItem(settingsItem)
            dshItem.submenu = dshMenu
            menu.addItem(dshItem)
            menu.addItem(.separator())
        }
        menu.addItem(.separator())
        if !forStatusBar {
            menu.addItem(viz)
        }
        let quit = NSMenuItem(title: "退出\(characterName)", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        menu.addItem(.separator())
        let openSet = NSMenuItem(title: "设置…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        openSet.target = self
        menu.addItem(openSet)
        return menu
    }

    @objc private func selectCharacter(_ sender: NSMenuItem) {
        guard !aiBusy, let id = sender.representedObject as? String,
              let next = characters.first(where: { $0.id == id }), next.id != character.id else { return }
        switchCharacter(to: next)
    }

    @discardableResult private func switchCharacter(to next: PetCharacter, announce: Bool = true, persist: Bool = true) -> Bool {
        let previous = character
        character = next
        guard loadAtlas() else {
            character = previous
            if announce { speak("角色图片无法读取，请检查素材文件。") }
            return false
        }
        currentRow = -1; currentCol = -1; currentSheetKey = ""
        animKey = ""; animElapsed = 0
        onceKind = ""; onceRepeatsLeft = 0; pendingOnce = ""; pendingOnceRepeats = nil
        ambientOnce = false; ambientReason = nil; chainedExtraKind = nil
        nextExtraWorkActionAt = 0
        completionWorkTiming.reset()
        directWorkTiming = nil
        systemActivity.resetForCostumeChange()
        dragging = false; dragMoved = false; wasHovering = false
        lookUntil = 0; lastLookDir = -1
        blinkAt = 0; blinkUntil = 0; blinkDoubleAt = 0; glanceAt = 0; glanceUntil = 0
        lastClickAction = nil; clickActionBag.removeAll(); queuedClickKind = nil; lastSpokenLine = ""; lastDirSpokenSlot = -1
        mood = .calm; moodUntil = 0; petStreak = 0; lastPetAt = 0
        bubbleVisible = false; bubbleWindow?.orderOut(nil)
        show(row: 0, col: 0)
        statusItem?.button?.toolTip = "\(character.menuTitle) · Roxy"
        refreshStatusIcon()                       // 图标跟着角色走
        statusItem?.menu = makeMenu(forStatusBar: true)
        settingsWindow?.title = "\(characterName) · 设置"
        historyWindow?.title = "\(characterName) · \(character.historyTitle)"
        refreshHistoryWindow()
        if announce {
            greeted = true
            lastInteractAt = CACurrentMediaTime()
            setPetHidden(false)
            let greeting = randomOf(lines("greeting", GREETINGS))
            speak(greeting.isEmpty ? character.menuTitle : greeting)
            triggerWaveOnce()
        }
        return true
    }

    @objc private func reloadCharacters() {
        guard !aiBusy else { return }
        characters = PetCharacter.loadCatalog()
        let next = characters.first(where: { $0.id == character.id }) ?? characters[0]
        switchCharacter(to: next)
    }

    @objc private func openCharactersFolder() {
        let folder = PetCharacter.customDirectory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let guide = folder.appendingPathComponent("添加角色.txt")
            if !FileManager.default.fileExists(atPath: guide.path) {
                let text = "每个角色放在独立子文件夹，包含 character.json 和透明 PNG 序列帧图。序列帧图使用 8 列 × 11 行，动作顺序与 Roxy 相同。可复制项目 02-assets/characters 中的角色文件夹作为模板，修改 id、characterID、name、appearance、actionVerb、persona 和图片。完成后，在角色菜单选择「重新载入角色与语料」。详细说明见仓库 07-docs/角色与语料扩展.md。"
                try text.write(to: guide, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(folder)
        } catch { speak("角色文件夹暂时无法打开。") }
    }

    /// Offline integration checks against the packaged resources. No preferences, files or network changed.
    func runCharacterChecks() {
        deterministicActionChecks = true
        defer { deterministicActionChecks = false }
        var seen = Set<String>()
        var prior: String? = nil
        for entropy in 0..<100 {
            let choice = Self.variedChoice(["rest", "focus", "greet"], previous: prior, entropy: UInt(entropy / 3))
            precondition(choice != prior && ["rest", "focus", "greet"].contains(choice))
            seen.insert(choice); prior = choice
        }
        precondition(seen.count == 3 && Self.variedChoice(["only"], previous: "only", entropy: 99) == "only")
        print("PASS: context-scoped random selection, no immediate repeats, all eligible variants reachable and single-action fallback.")
        Self.runSystemActivityChecks()
        Self.runCompletionWorkTimingChecks()
        precondition(Set(characters.map(\.id)).isSuperset(of: ["roxy", "roxy-nohat", "eris-short", "eris-long", "sylphie-adult", "sylphie-chibi"]))
        let roxyBase = characters.first { $0.id == "roxy" }!
        let roxyNohat = characters.first { $0.id == "roxy-nohat" }!
        precondition(roxyNohat.isRoxy && roxyNohat.characterID == roxyBase.characterID && roxyNohat.speech == roxyBase.speech && roxyNohat.persona == roxyBase.persona, "Roxy appearances share one identity, corpus and persona")
        let sylphieLooks = characters.filter { $0.characterID == "sylphie" }
        precondition(sylphieLooks.first?.id == "sylphie-adult", "Sylphie defaults to the approved daily outfit")
        precondition(sylphieLooks.first?.speech == sylphieLooks.last?.speech, "Sylphie appearances share one corpus")
        loadSpeechExtras()
        for _ in 0..<3 {
            for profile in characters {
                precondition(switchCharacter(to: profile, announce: false, persist: false), "Atlas failed: \(profile.id)")
                precondition(frames.count == 11 && masks.count == 11 && frames.allSatisfy { $0.count == 8 })
                precondition(currentImage != nil && currentRow == 0 && currentCol == 0)
                precondition(currentSheetKey == "base")
                if ["roxy-nohat", "sylphie-adult", "sylphie-chibi"].contains(profile.id) {
                    precondition(Set(extraClips.keys) == Set(["daily-rest", "daily-focus", "daily-greet"]), "Daily actions missing or costume clips mixed")
                }
                if ["roxy-nohat", "eris-short", "eris-long", "sylphie-adult", "sylphie-chibi"].contains(profile.id) {
                    let bitmap = frames[0][0].cgImage(forProposedRect: nil, context: nil, hints: nil)!
                    precondition(bitmap.width == 384 && bitmap.height == 416, "Retina pixels lost: \(profile.id)")
                }
                let usedColumns = [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8]
                for row in 0..<11 { for col in 0..<usedColumns[row] {
                    precondition(masks[row][col].filter { $0 > 64 }.count > 500, "Empty required frame \(profile.id) \(row)/\(col)")
                } }
                for status in [true, false] {
                    let menu = makeMenu(forStatusBar: status)
                    precondition(menu.items.contains { $0.title == "\(profile.actionTitle)（聊天 / 做事）" })
                    precondition(menu.items.contains { $0.title == "退出\(profile.name)" })
                    precondition(menu.items.contains { $0.title == "查看\(profile.historyTitle)" })
                    let extraTitles = Set(extraClips.values.map { $0.description.title })
                    precondition(!menu.items.contains { extraTitles.contains($0.title) },
                                 "State-driven character actions must not appear as menu commands")
                    let picker = menu.items.first!.submenu!
                    precondition(picker.items.filter { $0.state == .on }.count == 1)
                    precondition(picker.items.first { $0.state == .on }?.representedObject as? String == profile.id)
                    let byID = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
                    var previousIdentity: String?
                    var separated = false
                    var visited = Set<String>()
                    for item in picker.items {
                        if item.isSeparatorItem { separated = true; continue }
                        guard let id = item.representedObject as? String, let entry = byID[id] else { continue }
                        if let previous = previousIdentity {
                            precondition(separated == (previous != entry.characterID), "Separator must divide identities only")
                        }
                        if previousIdentity != entry.characterID {
                            precondition(visited.insert(entry.characterID).inserted, "Costumes must stay together")
                        }
                        previousIdentity = entry.characterID
                        separated = false
                        precondition(item.title == entry.menuTitle)
                    }
                }
                precondition(!lines("chat", CHAT_LINES).isEmpty)
                precondition(!lines("greeting", GREETINGS).isEmpty)
                if !profile.isRoxy {
                    precondition(lines("chat", CHAT_LINES) == profile.speech["chat"])
                    precondition(!characterPersonaSystem("测试").contains("你是《无职转生》的洛琪希"))
                    precondition(!characterHourlyLine(13).contains("{h}"))
                }
            }
        }
        runExtraActionChecks()
        let originalID = character.id
        var broken = character
        broken.atlasURL = URL(fileURLWithPath: "/nonexistent-eris-atlas.png")
        precondition(!switchCharacter(to: broken, announce: false, persist: false))
        precondition(character.id == originalID && frames.count == 11)
        let oldJSON = Data("[{\"t\":0,\"role\":\"roxy\",\"text\":\"原有记录\"}]".utf8)
        taskHistory = try! JSONDecoder().decode([TaskRecord].self, from: oldJSON)
        taskHistory.append(TaskRecord(t: 1, role: "roxy", text: "新记录", characterID: "eris", characterName: "艾丽丝"))
        taskHistory.append(TaskRecord(t: 2, role: "roxy", text: "希露菲记录", characterID: "sylphie", characterName: "希露菲"))
        let html = historyHTML()
        precondition(html.contains("洛琪希") && html.contains("艾丽丝") && html.contains("希露菲"))
        print("PASS: \(characters.count) appearances, 3 switching cycles, all used animation frames, native Retina pixels, both menus, isolated corpus/persona, failed-image rollback, legacy/new history, optional costume clips and fallback.")
    }

    private static func runSystemActivityChecks() {
        var activity = SystemActivityState()
        activity.sample(idleSeconds: 0.1, at: 0)
        precondition(!activity.pendingReturnSalute, "The first startup input must not invent an absence")
        activity.sample(idleSeconds: 181, at: 200)
        activity.sample(idleSeconds: 0.1, at: 201)
        precondition(activity.pendingReturnSalute && activity.takeReturnSalute(at: 201))
        activity.peakIdleSeconds = 181
        activity.sample(idleSeconds: 2.9, at: 320.9)
        precondition(!activity.pendingReturnSalute, "Return salutes require a full 120-second cooldown")
        activity.peakIdleSeconds = 181
        activity.sample(idleSeconds: 0, at: 321)
        precondition(activity.pendingReturnSalute && activity.takeReturnSalute(at: 321))
        activity.sample(idleSeconds: .infinity, at: 322)
        precondition(!activity.canAnimateAutomatically, "Unavailable idle measurements must disable automatic actions")

        var wake = SystemActivityState()
        wake.receive(.willSleep)
        wake.receive(.screensDidSleep)
        wake.receive(.sessionDidResignActive)
        wake.sample(idleSeconds: 0.1, at: 10) // The wake key arrived before the workspace finished resuming.
        precondition(wake.isPaused && !wake.pendingReturnSalute)
        wake.receive(.didWake)
        wake.receive(.sessionDidBecomeActive)
        precondition(wake.isPaused)
        wake.receive(.screensDidWake)
        precondition(!wake.isPaused && wake.awaitingWakeInput && wake.idleSeconds == nil)
        wake.sample(idleSeconds: 1.1, at: 11) // No second key or mouse event is needed.
        precondition(wake.pendingReturnSalute && wake.takeReturnSalute(at: 11))
        for signal in [WorkspaceActivitySignal.didWake, .screensDidWake, .sessionDidBecomeActive] { wake.receive(signal) }
        wake.sample(idleSeconds: 2.1, at: 12)
        precondition(!wake.awaitingWakeInput && !wake.pendingReturnSalute, "Resume notifications must coalesce after one return")
        wake.receive(.willSleep); wake.receive(.didWake)
        wake.sample(idleSeconds: 0.1, at: 20)
        precondition(!wake.pendingReturnSalute, "Repeated wakes during cooldown must stay quiet")
        wake.receive(.willSleep); wake.receive(.didWake)
        wake.sample(idleSeconds: 0.1, at: 131)
        precondition(wake.pendingReturnSalute && wake.takeReturnSalute(at: 131))
        wake.sample(idleSeconds: 181, at: 400)
        wake.sample(idleSeconds: 0.1, at: 401)
        precondition(wake.pendingReturnSalute, "Input-idle return must also work without session notifications")
        wake.idlePosePlayed = true
        wake.resetForCostumeChange()
        precondition(!wake.pendingReturnSalute && !wake.idlePosePlayed && wake.idleSeconds == nil)

        var acknowledged = SystemActivityState()
        acknowledged.sample(idleSeconds: 181, at: 500)
        acknowledged.acknowledgeReturn(at: 501)
        acknowledged.sample(idleSeconds: 0.1, at: 501)
        precondition(!acknowledged.pendingReturnSalute, "A response before the next idle sample already acknowledges the return")
        acknowledged.pendingReturnSalute = true
        acknowledged.acknowledgeReturn(at: 502)
        precondition(!acknowledged.pendingReturnSalute && !acknowledged.takeReturnSalute(at: 503))

        let discharging = "Now drawing from 'Battery Power'\n -InternalBattery-0 64%; discharging; 3:00 remaining"
        let charging = "Now drawing from 'AC Power'\n -InternalBattery-0 64%; charging; 1:00 remaining"
        let charged = "Now drawing from 'AC Power'\n -InternalBattery-0 100%; charged; 0:00 remaining"
        let notCharging = "Now drawing from 'AC Power'\n -InternalBattery-0 64%; AC attached; not charging"
        precondition(parseBatteryStatus(discharging)?.charging == false && parseBatteryStatus(discharging)?.level == 64)
        precondition(parseBatteryStatus(charging)?.charging == true && parseBatteryStatus(charged)?.charging == true)
        precondition(parseBatteryStatus(notCharging)?.charging == false)
        precondition(parseBatteryStatus("Now drawing from 'AC Power'\n -InternalBattery-0 64%; discharging;")?.charging == false)
        precondition(parseBatteryStatus("No batteries available") == nil)
        precondition(parseBatteryStatus("Battery 120%; charging;") == nil)
        print("PASS: pure aggregate-idle return/cooldown, wake-key ordering and deduplication, costume reset, exact battery status parsing.")
    }

    private func runExtraActionChecks() {
        let previous = character
        let expectedByCostume: [(String, [String: Int])] = [
            ("roxy", ["staff-idle": 8, "staff-channel": 8, "water-cast": 8, "staff-salute": 6, "cumulonimbus": 8]),
            ("eris-short", ["sword-idle": 8, "sword-practice": 8, "sword-salute": 6]),
            ("eris-long", ["sword-idle": 8, "sword-practice": 8, "sword-salute": 6]),
            ("roxy-nohat", ["daily-rest": 4, "daily-focus": 4, "daily-greet": 4]),
            ("sylphie-adult", ["daily-rest": 4, "daily-focus": 4, "daily-greet": 4]),
            ("sylphie-chibi", ["daily-rest": 4, "daily-focus": 4, "daily-greet": 4]),
        ]
        var practiceFrames: [String: NSImage] = [:]
        var checked = 0
        for (id, expected) in expectedByCostume {
            let profile = characters.first { $0.id == id }!
            precondition(switchCharacter(to: profile, announce: false, persist: false))
            precondition(onceKind.isEmpty && pendingOnce.isEmpty && chainedExtraKind == nil && !dragging
                         && currentSheetKey == "base" && currentImage === frames[0][0],
                         "Switching costume must clear the previous extra action and its queue")
            guard let directory = extraActionsDirectory(),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
                precondition(extraClips.isEmpty)
                precondition(Self.decodeExtraClips(data: nil, image: nil).isEmpty)
                continue
            }
            if id != "roxy" {
                precondition(directory == profile.atlasURL?.deletingLastPathComponent().appendingPathComponent("actions", isDirectory: true),
                             "Costume extras must load beside that costume's own atlas")
            }
            checkExtraPlayback(expected: expected, behavior: extraBehavior!, directory: directory)
            if let frame = extraClips["sword-practice"]?.frames.first { practiceFrames[id] = frame }
            let behavior = extraBehavior!
            startOnce(behavior.idle, repeats: 1)
            showExtra(extraClips[behavior.idle]!, col: 0)
            dragStarted(atMouseX: 0, atMouseY: 0)
            startOnce("wave", repeats: 1)
            chainedExtraKind = behavior.done // Exercise switching while an extra and a queue are active.
            checked += 1
        }
        if let short = practiceFrames["eris-short"], let long = practiceFrames["eris-long"] {
            precondition(short !== long, "Eris appearances must not share the same cached sword frame")
            let shortPixels = short.tiffRepresentation
            let longPixels = long.tiffRepresentation
            precondition(shortPixels != nil && longPixels != nil && shortPixels != longPixels,
                         "Eris sword-practice frames must come from their independent costume artwork")
        }
        for id in ["roxy-nohat", "sylphie-adult", "sylphie-chibi"] {
            let profile = characters.first { $0.id == id }!
            precondition(switchCharacter(to: profile, announce: false, persist: false))
            precondition(Set(extraClips.keys) == Set(["daily-rest", "daily-focus", "daily-greet"]) && currentSheetKey == "base" && onceKind.isEmpty && pendingOnce.isEmpty
                         && chainedExtraKind == nil && !dragging,
                         "Optional clips or playback state leaked across costume switching")
        }
        precondition(switchCharacter(to: previous, announce: false, persist: false))
        print("PASS: \(checked) optional costume sidecars, independent Eris sword artwork, strict metadata fallback, base/extra cache, native pixels, old reactions and reply ordering, drag queue, idle interruption, work-cycle boundary.")
    }

    private func checkExtraPlayback(expected: [String: Int], behavior: ExtraBehavior, directory: URL) {
        precondition(Set(extraClips.keys).isSuperset(of: Set(expected.keys)), "Bundled costume clips are incomplete")
        for (id, count) in expected {
            let clip = extraClips[id]!
            precondition(clip.frames.count == count)
            for frame in clip.frames {
                let cg = frame.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                precondition(cg.width == 384 && cg.height == 416, "Extra clip lost native Retina pixels")
            }
        }
        let data = try! Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let image = NSImage(contentsOf: directory.appendingPathComponent("spritesheet.png"))!
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(Self.decodeExtraClips(data: nil, image: cg).isEmpty)
        precondition(Self.decodeExtraClips(data: data, image: nil).isEmpty)
        precondition(Self.decodeExtraClips(data: Data("{".utf8), image: cg).isEmpty)
        var invalid = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        invalid["rows"] = 0
        precondition(Self.decodeExtraClips(data: try! JSONSerialization.data(withJSONObject: invalid), image: cg).isEmpty)
        invalid = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        var entries = invalid["actions"] as! [[String: Any]]
        entries[1]["id"] = entries[0]["id"]
        invalid["actions"] = entries
        precondition(Self.decodeExtraClips(data: try! JSONSerialization.data(withJSONObject: invalid), image: cg).isEmpty)
        invalid = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        entries = invalid["actions"] as! [[String: Any]]
        entries[0]["frameDuration"] = 0
        invalid["actions"] = entries
        precondition(Self.decodeExtraClips(data: try! JSONSerialization.data(withJSONObject: invalid), image: cg).isEmpty)

        let stableMask = hoverMask
        let idle = extraClips[behavior.idle]!
        show(row: 0, col: 0)
        showExtra(idle, col: 0)
        precondition(currentSheetKey == "extra:" + character.id + ":" + behavior.idle && currentImage === idle.frames[0])
        precondition(hoverMask == stableMask, "Transient magic effects must not enlarge hit testing")
        show(row: 0, col: 0)
        precondition(currentSheetKey == "base" && currentImage === frames[0][0], "Base/extra frame 0 cache collision")
        startOnce(behavior.idle, repeats: 1)
        animElapsed = 1
        startOnce(behavior.idle, repeats: 1)
        precondition(animElapsed == 0 && onceRepeatsLeft == 1, "Same action must restart")

        triggerCompletionReaction()
        precondition(onceKind == "wave" && onceRepeatsLeft == WAVE_REPEAT && chainedExtraKind == behavior.done)
        advanceSequence(row: 3, sequence: WAVE_SEQ, loop: false, extraID: nil,
                        dt: WAVE_SEQ.reduce(0) { $0 + $1.1 } * Double(WAVE_REPEAT) + 0.01)
        precondition(onceKind == behavior.done, "Original completion wave must finish before the appended finish")
        let finish = extraClips[behavior.done]!
        advanceSequence(row: 0, sequence: finish.sequence, loop: false, extraID: behavior.done,
                        dt: finish.sequence.reduce(0) { $0 + $1.1 } + 0.01)
        precondition(onceKind.isEmpty && currentSheetKey == "base" && currentImage === frames[0][0])

        for kind in ["wave", "jump"] {
            let repeats = kind == "wave" ? WAVE_REPEAT : 1
            startOnce(kind, repeats: repeats)
            animKey = "once-" + kind
            animElapsed = 0.1
            appendReplyExtraAction()
            precondition(onceKind == kind && onceRepeatsLeft == repeats && animElapsed == 0.1,
                         "A reply finish must preserve the user's current reaction and progress")
            precondition(animKey == "once-" + kind && chainedExtraKind == behavior.done)
            let old = oncePlayback(for: kind)!
            advanceSequence(row: old.row, sequence: old.sequence, loop: false, extraID: nil,
                            dt: old.sequence.reduce(0) { $0 + $1.1 } * Double(repeats) - 0.1 + 0.01)
            precondition(onceKind == behavior.done, "The finish must follow the completed user reaction")
            advanceSequence(row: 0, sequence: finish.sequence, loop: false, extraID: behavior.done,
                            dt: finish.sequence.reduce(0) { $0 + $1.1 } + 0.01)
        }

        startOnce("jump", repeats: 1)
        animElapsed = 0.1
        dragStarted(atMouseX: 0, atMouseY: 0)
        dragMoved = true
        startOnce("wave", repeats: WAVE_REPEAT)
        appendReplyExtraAction()
        precondition(onceKind == "jump" && animElapsed == 0.1 && pendingOnce == "wave"
                     && pendingOnceRepeats == WAVE_REPEAT && chainedExtraKind == behavior.done,
                     "A reply finish must not overwrite drag-paused or drag-queued user actions")
        dragEnded()
        precondition(onceKind == "wave" && onceRepeatsLeft == WAVE_REPEAT && chainedExtraKind == behavior.done)
        advanceSequence(row: 3, sequence: WAVE_SEQ, loop: false, extraID: nil,
                        dt: WAVE_SEQ.reduce(0) { $0 + $1.1 } * Double(WAVE_REPEAT) + 0.01)
        precondition(onceKind == behavior.done)
        advanceSequence(row: 0, sequence: finish.sequence, loop: false, extraID: behavior.done,
                        dt: finish.sequence.reduce(0) { $0 + $1.1 } + 0.01)

        startOnce("jump", repeats: 1)
        dragStarted(atMouseX: 0, atMouseY: 0) // Mouse held without moving: the old jump can still finish.
        startOnce("wave", repeats: 1)
        appendReplyExtraAction()
        advanceSequence(row: 4, sequence: JUMP_SEQ, loop: false, extraID: nil,
                        dt: JUMP_SEQ.reduce(0) { $0 + $1.1 } + 0.01)
        precondition(onceKind.isEmpty && pendingOnce == "wave" && chainedExtraKind == behavior.done,
                     "Finishing a clip during a held press must not replace the pending old action")
        dragEnded()
        precondition(onceKind == "wave" && chainedExtraKind == behavior.done)
        advanceSequence(row: 3, sequence: WAVE_SEQ, loop: false, extraID: nil,
                        dt: WAVE_SEQ.reduce(0) { $0 + $1.1 } + 0.01)
        precondition(onceKind == behavior.done)
        advanceSequence(row: 0, sequence: finish.sequence, loop: false, extraID: behavior.done,
                        dt: finish.sequence.reduce(0) { $0 + $1.1 } + 0.01)
        beginOnce(behavior.idle, repeats: 1, ambient: true)
        appendReplyExtraAction()
        precondition(onceKind == behavior.done && !ambientOnce, "A reply may replace only an ambient pose")
        advanceSequence(row: 0, sequence: finish.sequence, loop: false, extraID: behavior.done,
                        dt: finish.sequence.reduce(0) { $0 + $1.1 } + 0.01)

        startOnce(behavior.done, repeats: 1)
        dragStarted(atMouseX: 0, atMouseY: 0)
        dragMoved = true
        show(row: 1, col: 0)
        let pausedElapsed = animElapsed
        advanceSequence(row: 0, sequence: finish.sequence, loop: false, extraID: behavior.done, dt: 0.2)
        precondition(animElapsed == pausedElapsed && currentSheetKey == "base" && currentRow == 1)
        startOnce(behavior.salute, repeats: 1)
        precondition(pendingOnce == behavior.salute, "New requests during dragging must remain queued")
        dragEnded()
        precondition(onceKind == behavior.salute && pendingOnce.isEmpty)
        beginOnce(behavior.idle, repeats: 1, ambient: true)
        dragStarted(atMouseX: 0, atMouseY: 0)
        precondition(onceKind.isEmpty, "Dragging must interrupt optional idle poses")
        dragEnded()
        beginOnce(behavior.idle, repeats: 1, ambient: true)
        triggerJump()
        precondition(onceKind == "jump" && !ambientOnce, "Existing touch reactions must interrupt optional idle poses")
        checkClickActions(behavior: behavior)

        checkSystemDrivenExtras(behavior: behavior)
        checkSignatureCompletion(behavior: behavior)
    }

    private func checkClickActions(behavior: ExtraBehavior) {
        lastClickAction = nil; clickActionBag = []; queuedClickKind = nil
        precondition(nextClickAction() == "wave")
        let expected = Set(["wave", "jump"] + extraClips.keys.sorted())
        var prior = "wave"
        for _ in 0..<4 {
            var seen = Set<String>()
            for _ in 0..<expected.count {
                let chosen = nextClickAction()
                precondition(chosen != prior && oncePlayback(for: chosen) != nil)
                seen.insert(chosen); prior = chosen
            }
            precondition(seen == expected, "Every old/new click action must appear once in each shuffled round")
        }
        lastClickAction = nil; clickActionBag = []; queuedClickKind = nil
        onceKind = ""; pendingOnce = ""; chainedExtraKind = nil; dragging = false
        clickReaction()
        precondition(onceKind == "wave" && onceRepeatsLeft == 1)
        animElapsed = 0.12
        clickReaction()
        let queued = queuedClickKind!
        let remaining = clickActionBag.count
        for _ in 0..<50 { clickReaction() }
        precondition(onceKind == "wave" && animElapsed == 0.12 && queuedClickKind == queued
                     && clickActionBag.count == remaining, "Fast clicks must coalesce without restarting or consuming more actions")
        chainedExtraKind = behavior.done
        advanceSequence(row: 3, sequence: WAVE_SEQ, loop: false, extraID: nil,
                        dt: WAVE_SEQ.reduce(0) { $0 + $1.1 } + 0.01)
        precondition(onceKind == behavior.done && queuedClickKind == queued, "Completion chain must precede queued clicks")
        let finish = extraClips[behavior.done]!
        advanceSequence(row: 0, sequence: finish.sequence, loop: false, extraID: behavior.done,
                        dt: finish.sequence.reduce(0) { $0 + $1.1 } + 0.01)
        precondition(onceKind == queued && queuedClickKind == nil)
        let playback = oncePlayback(for: queued)!
        advanceSequence(row: playback.row, sequence: playback.sequence, loop: false, extraID: playback.extraID,
                        dt: playback.sequence.reduce(0) { $0 + $1.1 } + 0.01)
        precondition(onceKind.isEmpty)
        let saved = extraClips
        extraClips = [:]; lastClickAction = nil; clickActionBag = []
        precondition(nextClickAction() == "wave")
        precondition(Set((0..<2).map { _ in nextClickAction() }) == Set(["wave", "jump"]))
        extraClips = saved; lastClickAction = nil; clickActionBag = []; queuedClickKind = nil
        print("PASS: \(character.id) complete shuffled click rounds, no immediate repeats, rapid-click coalescing, completion-chain priority and missing-pack fallback.")
    }

    private static func runCompletionWorkTimingChecks() {
        var timing = CompletionWorkTiming()
        timing.update(workingSources: ["claude"], at: 10)
        timing.update(workingSources: ["claude", "codex"], at: 129.99)
        precondition(abs(timing.duration(for: "claude", at: 129.99)! - 119.99) < 0.0001)
        precondition(timing.duration(for: "codex", at: 129.99) == 0)
        precondition(timing.duration(for: "unobserved", at: 130) == nil,
                     "A fresh done event must not borrow another source's work interval")
        precondition(timing.duration(for: "claude", at: 130) == CompletionWorkTiming.signatureThreshold)
        timing.update(workingSources: ["codex"], at: 130)
        precondition(timing.duration(for: "claude", at: 131) == nil,
                     "Completed/notice/missing/stale/cancelled sources must clear their work interval")
        timing.update(workingSources: [], at: 500)
        timing.update(workingSources: ["claude"], at: 600)
        precondition(timing.duration(for: "claude", at: 601) == 1,
                     "A later task cannot inherit elapsed time from a previous task or idle period")
        timing.reset()
        precondition(timing.startedAtBySource.isEmpty)
        let direct = DirectWorkTiming(startedAt: 10, costumeID: "roxy")
        precondition(direct.duration(for: "roxy", at: 130, successful: true) == 120)
        precondition(direct.duration(for: "roxy", at: 130, successful: false) == nil)
        precondition(direct.duration(for: "eris-short", at: 130, successful: true) == nil)
        precondition(direct.duration(for: "roxy", at: .nan, successful: true) == nil)
        print("PASS: per-source continuous work duration, 120-second boundary, unrelated-task isolation, interrupted-work reset and failed direct-task exclusion.")
    }

    private func checkSignatureCompletion(behavior: ExtraBehavior) {
        precondition(completionExtraID(workDuration: nil) == behavior.done)
        precondition(completionExtraID(workDuration: 119.999) == behavior.done)
        precondition(completionExtraID(workDuration: .infinity) == behavior.done)
        precondition(completionExtraID(workDuration: -1) == behavior.done)
        if character.id != "roxy" {
            precondition(completionExtraID(workDuration: 500) == behavior.done,
                         "Long tasks must keep each Eris appearance's existing sword finish")
            return
        }
        guard let storm = extraClips["cumulonimbus"] else {
            precondition(completionExtraID(workDuration: 120) == behavior.done)
            return
        }
        precondition(storm.frames.count == 8 && completionExtraID(workDuration: 120) == "cumulonimbus")
        extraClips.removeValue(forKey: "cumulonimbus")
        precondition(completionExtraID(workDuration: 500) == behavior.done,
                     "An old optional action pack must safely fall back to its existing water spell")
        extraClips["cumulonimbus"] = storm
        triggerCompletionReaction(workDuration: 120)
        precondition(onceKind == "wave" && onceRepeatsLeft == WAVE_REPEAT && chainedExtraKind == "cumulonimbus")
        advanceSequence(row: 3, sequence: WAVE_SEQ, loop: false, extraID: nil,
                        dt: WAVE_SEQ.reduce(0) { $0 + $1.1 } * Double(WAVE_REPEAT) + 0.01)
        precondition(onceKind == "cumulonimbus", "The signature spell must follow the complete original wave")
        advanceSequence(row: 0, sequence: storm.sequence, loop: false, extraID: "cumulonimbus",
                        dt: storm.sequence.reduce(0) { $0 + $1.1 } + 0.01)
        precondition(onceKind.isEmpty && currentSheetKey == "base")
        startOnce("jump", repeats: 1)
        animElapsed = 0.1
        appendReplyExtraAction(workDuration: 120)
        precondition(onceKind == "jump" && animElapsed == 0.1 && chainedExtraKind == "cumulonimbus",
                     "A long task reply must preserve an unfinished original user reaction")
        advanceSequence(row: 4, sequence: JUMP_SEQ, loop: false, extraID: nil,
                        dt: JUMP_SEQ.reduce(0) { $0 + $1.1 } + 0.01)
        precondition(onceKind == "cumulonimbus")
        advanceSequence(row: 0, sequence: storm.sequence, loop: false, extraID: "cumulonimbus",
                        dt: storm.sequence.reduce(0) { $0 + $1.1 } + 0.01)

        directWorkTiming = DirectWorkTiming(startedAt: 10, costumeID: character.id)
        precondition(takeDirectWorkDuration(successful: false, at: 500) == nil && directWorkTiming == nil,
                     "Failed tasks must consume and clear their timing without a success spell")
        precondition(takeDirectWorkDuration(successful: true, at: 600) == nil,
                     "A later reply cannot reuse a failed task's timing")
        completionWorkTiming.update(workingSources: ["claude"], at: 10)
        directWorkTiming = DirectWorkTiming(startedAt: 10, costumeID: character.id)
        let sameCostume = character
        precondition(switchCharacter(to: sameCostume, announce: false, persist: false))
        precondition(completionWorkTiming.startedAtBySource.isEmpty && directWorkTiming == nil
                     && chainedExtraKind == nil && onceKind.isEmpty,
                     "Costume reload/switch must clear old task timing and pending storm playback")
        print("PASS: optional cumulonimbus threshold/fallback, original-wave/reply ordering, failed-task consumption and costume timing reset.")
    }

    private func checkSystemDrivenExtras(behavior: ExtraBehavior) {
        onceKind = ""; onceRepeatsLeft = 0; chainedExtraKind = nil; ambientOnce = false; ambientReason = nil
        pendingOnce = ""; pendingOnceRepeats = nil; dragging = false; dragMoved = false
        lookUntil = 0; glanceUntil = 0; workState = "idle"; petHidden = false
        nextExtraWorkActionAt = 0
        systemActivity = SystemActivityState()
        let interactionBefore = lastInteractAt
        func drive(_ seconds: Double, at time: Double) {
            acceptSystemActivity(idleSeconds: seconds, at: time)
            pollExtraActions(now: time, dt: 0.01, activityNow: time)
        }
        func finishExtra(_ id: String) {
            let clip = extraClips[id]!
            advanceSequence(row: 0, sequence: clip.sequence, loop: false, extraID: id,
                            dt: clip.sequence.reduce(0) { $0 + $1.1 } + 0.01)
        }
        for second in 0...90 {
            drive(0.1, at: Double(second))
            precondition(onceKind.isEmpty, "Active computer input must not randomly draw a weapon")
        }
        drive(59.9, at: 150)
        precondition(onceKind.isEmpty)
        drive(60, at: 150.1)
        precondition(onceKind == behavior.idle && ambientReason == .idle && systemActivity.idlePosePlayed)
        finishExtra(behavior.idle)
        drive(70, at: 160.1)
        precondition(onceKind.isEmpty, "One continuous idle episode permits only one idle pose")
        drive(0.1, at: 161.1)
        precondition(!systemActivity.idlePosePlayed)
        drive(60, at: 221.1)
        precondition(onceKind == behavior.idle)
        drive(0.1, at: 222.1)
        precondition(onceKind.isEmpty, "Returning computer input must cancel an idle weapon pose")

        systemActivity = SystemActivityState()
        acceptSystemActivity(idleSeconds: 60, at: 300)
        startOnce("wave", repeats: 1)
        pollExtraActions(now: 300, dt: 0.01, activityNow: 300)
        precondition(onceKind == "wave" && !systemActivity.idlePosePlayed)
        advanceSequence(row: 3, sequence: WAVE_SEQ, loop: false, extraID: nil,
                        dt: WAVE_SEQ.reduce(0) { $0 + $1.1 } + 0.01)
        dragging = true
        startOnce("jump", repeats: 1)
        pollExtraActions(now: 300, dt: 0.01, activityNow: 300)
        precondition(pendingOnce == "jump" && !systemActivity.idlePosePlayed)
        dragEnded()
        advanceSequence(row: 4, sequence: JUMP_SEQ, loop: false, extraID: nil,
                        dt: JUMP_SEQ.reduce(0) { $0 + $1.1 } + 0.01)
        chainedExtraKind = behavior.done
        pollExtraActions(now: 300, dt: 0.01, activityNow: 300)
        precondition(chainedExtraKind == behavior.done && !systemActivity.idlePosePlayed)
        chainedExtraKind = nil
        lookUntil = 305
        pollExtraActions(now: 300, dt: 0.01, activityNow: 300)
        precondition(onceKind.isEmpty && !systemActivity.idlePosePlayed)
        lookUntil = 0
        workState = "working"; nextExtraWorkActionAt = 500
        pollExtraActions(now: 300, dt: 0.01, activityNow: 300)
        precondition(onceKind.isEmpty && !systemActivity.idlePosePlayed)
        workState = "idle"
        pollExtraActions(now: 300, dt: 0.01, activityNow: 300)
        precondition(onceKind == behavior.idle)
        cancelAmbientOnce()

        systemActivity = SystemActivityState()
        acceptSystemActivity(idleSeconds: 181, at: 500)
        startOnce("wave", repeats: 1)
        drive(0.1, at: 501)
        precondition(systemActivity.pendingReturnSalute && onceKind == "wave")
        advanceSequence(row: 3, sequence: WAVE_SEQ, loop: false, extraID: nil,
                        dt: WAVE_SEQ.reduce(0) { $0 + $1.1 } + 0.01)
        workState = "working"; nextExtraWorkActionAt = 1000
        pollExtraActions(now: 501, dt: 0.01, activityNow: 501)
        precondition(onceKind.isEmpty && systemActivity.pendingReturnSalute)
        workState = "idle"; lookUntil = 510
        pollExtraActions(now: 501, dt: 0.01, activityNow: 501)
        precondition(onceKind.isEmpty && systemActivity.pendingReturnSalute)
        lookUntil = 0; dragging = true
        startOnce("jump", repeats: 1)
        pollExtraActions(now: 501, dt: 0.01, activityNow: 501)
        precondition(pendingOnce == "jump" && systemActivity.pendingReturnSalute && chainedExtraKind == nil)
        dragEnded()
        advanceSequence(row: 4, sequence: JUMP_SEQ, loop: false, extraID: nil,
                        dt: JUMP_SEQ.reduce(0) { $0 + $1.1 } + 0.01)
        pollExtraActions(now: 501.1, dt: 0.01, activityNow: 501.1)
        precondition(onceKind == behavior.salute && ambientReason == .returnSalute
                     && !systemActivity.pendingReturnSalute && chainedExtraKind == nil)
        drive(0.1, at: 502.1)
        precondition(onceKind == behavior.salute, "One return greeting may finish while typing continues")
        finishExtra(behavior.salute)
        pollExtraActions(now: 502.1, dt: 0.01, activityNow: 502.1)
        precondition(onceKind.isEmpty)

        systemActivity = SystemActivityState()
        acceptSystemActivity(idleSeconds: 181, at: 700)
        acceptSystemActivity(idleSeconds: 0.1, at: 701)
        precondition(systemActivity.pendingReturnSalute)
        triggerCompletionReaction(activityNow: 701)
        precondition(!systemActivity.pendingReturnSalute && onceKind == "wave" && chainedExtraKind == behavior.done)
        advanceSequence(row: 3, sequence: WAVE_SEQ, loop: false, extraID: nil,
                        dt: WAVE_SEQ.reduce(0) { $0 + $1.1 } * Double(WAVE_REPEAT) + 0.01)
        precondition(onceKind == behavior.done)
        finishExtra(behavior.done)
        drive(0.1, at: 702)
        precondition(onceKind.isEmpty && !systemActivity.pendingReturnSalute,
                     "Completion feedback must not be followed by a duplicate return salute")

        systemActivity = SystemActivityState()
        acceptSystemActivity(idleSeconds: 181, at: 710)
        startOnce("jump", repeats: 1)
        appendReplyExtraAction(activityNow: 711)
        drive(0.1, at: 711)
        precondition(onceKind == "jump" && chainedExtraKind == behavior.done && !systemActivity.pendingReturnSalute,
                     "A reply before the activity sample must preserve the old reaction without a second welcome")
        advanceSequence(row: 4, sequence: JUMP_SEQ, loop: false, extraID: nil,
                        dt: JUMP_SEQ.reduce(0) { $0 + $1.1 } + 0.01)
        finishExtra(behavior.done)
        systemActivity = SystemActivityState()
        acceptSystemActivity(idleSeconds: 181, at: 720)
        acknowledgeDesktopReturn(at: 721)
        drive(0.1, at: 721)
        precondition(onceKind.isEmpty && !systemActivity.pendingReturnSalute,
                     "Direct pet interaction acknowledges returning input before the 1Hz sample")

        systemActivity = SystemActivityState()
        beginOnce(behavior.idle, repeats: 1, ambient: true, reason: .idle)
        receiveWorkspaceActivity(.willSleep)
        receiveWorkspaceActivity(.screensDidSleep)
        receiveWorkspaceActivity(.sessionDidResignActive)
        precondition(onceKind.isEmpty && systemActivity.isPaused)
        acceptSystemActivity(idleSeconds: 0.1, at: 600)
        receiveWorkspaceActivity(.didWake)
        receiveWorkspaceActivity(.sessionDidBecomeActive)
        petHidden = true
        receiveWorkspaceActivity(.screensDidWake)
        drive(1.1, at: 601)
        precondition(petHidden && onceKind.isEmpty && systemActivity.pendingReturnSalute)
        petHidden = false
        pollExtraActions(now: 601, dt: 0.01, activityNow: 601)
        precondition(onceKind == behavior.salute && !systemActivity.pendingReturnSalute)
        receiveWorkspaceActivity(.didWake)
        receiveWorkspaceActivity(.screensDidWake)
        receiveWorkspaceActivity(.sessionDidBecomeActive)
        precondition(onceKind == behavior.salute, "Duplicate resume notifications must not cut or replay a greeting")
        finishExtra(behavior.salute)
        drive(2.1, at: 602)
        precondition(onceKind.isEmpty && !systemActivity.pendingReturnSalute)

        systemActivity = SystemActivityState()
        workState = "working"; nextExtraWorkActionAt = 799
        animKey = "work"; animElapsed = WORK_SEQ.reduce(0) { $0 + $1.1 } - 0.005
        drive(2.99, at: 800)
        precondition(onceKind.isEmpty, "Continuous input must postpone automatic practice")
        drive(3, at: 800.01)
        precondition(onceKind == behavior.work && ambientReason == .work)
        drive(0.1, at: 801)
        precondition(onceKind.isEmpty, "Input resumption must cancel automatic work gestures")
        nextExtraWorkActionAt = 803; animKey = "work"; animElapsed = 0.1
        drive(3, at: 804)
        precondition(onceKind.isEmpty, "A quiet gap still must not truncate an old work cycle")
        animElapsed = WORK_SEQ.reduce(0) { $0 + $1.1 } - 0.005
        pollExtraActions(now: 804, dt: 0.01, activityNow: 804)
        precondition(onceKind == behavior.work)
        cancelAmbientOnce()
        acceptSystemActivity(idleSeconds: 0.1, at: 805)
        startOnce(behavior.work, repeats: 1)
        pollExtraActions(now: 805, dt: 0.01, activityNow: 805)
        precondition(onceKind == behavior.work && !ambientOnce, "Event-triggered one-shots must not be treated as idle ambience")
        workState = "idle"
        systemActivity.idlePosePlayed = true
        systemActivity.pendingReturnSalute = true
        systemActivity.awaitingWakeInput = true
        let sameCostume = character
        precondition(switchCharacter(to: sameCostume, announce: false, persist: false))
        precondition(!systemActivity.idlePosePlayed && !systemActivity.pendingReturnSalute
                     && !systemActivity.awaitingWakeInput && systemActivity.idleSeconds == nil)
        precondition(lastInteractAt == interactionBefore, "System activity must not redefine pet-interaction moods")
        print("PASS: \(character.id) causal idle/return/wake actions, old-chain priority, hidden state, quiet-work boundary and event-trigger priority.")
    }

    // ---------- 右键菜单 ----------
    func showContextMenu(with event: NSEvent) {
        guard let v = petView else { return }
        NSMenu.popUpContextMenu(makeMenu(forStatusBar: false), with: event, for: v)
    }

    @objc private func resetPosition() {
        setPetHidden(false)
        placeDefaultPosition()
    }
    // 把当前内置语料导出为 JSON（就是 speech/<人物ID>.json 的生成方式）：
    //   ./Roxy.app/Contents/MacOS/Roxy --export-speech > 02-assets/speech/roxy.json
    func exportSpeechJSON() -> String {
        loadSpeechExtras()
        var out: [String: [String]] = [:]
        out["greeting"] = GREETINGS
        out["chat"] = CHAT_LINES
        out["hover"] = HOVER_LINES
        out["drag"] = DRAG_LINES
        out["look_end"] = LOOK_END_LINES
        out["lonely"] = LONELY_LINES
        out["morning"] = MORNING_LINES
        out["day"] = DAY_LINES
        out["evening"] = EVENING_LINES
        out["night"] = NIGHT_LINES
        out["weekend"] = WEEKEND_LINES
        out["workday"] = WORKDAY_LINES
        out["battery20"] = BATTERY_20
        out["battery10"] = BATTERY_10
        out["battery_full"] = BATTERY_FULL
        out["done"] = DONE_LINES
        out["notice"] = NOTICE_LINES
        out["ai_thinking"] = AI_THINKING
        out["ai_fail"] = AI_FAIL
        let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// ---------- 入口 ----------
let app = NSApplication.shared
let controller = PetController()
if CommandLine.arguments.contains("--self-test") {
    controller.runCharacterChecks()
    exit(0)
}
if CommandLine.arguments.contains("--export-speech") {
    print(controller.exportSpeechJSON())
    exit(0)
}
app.delegate = controller
app.run()
