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
import QuartzCore

// ============ 可调参数 ============
let WINDOW_SCALE: CGFloat = 0.75          // 显示缩放（0.75 → 144×156 点）
let LOOK_WINDOW_SECONDS: Double = 10      // 悬停触发后，"跟随"持续的秒数
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
    "这里就是小萌老师的桌面吗？嗯……是个让人安心的好地方呢，像旅途里歇脚的小屋。",
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
        controller?.dragStarted(atMouseX: dragStart.x)
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
    var window: NSWindow?
    var petView: PetView?

    private var frames: [[NSImage]] = []      // [row][col]
    private var masks: [[[UInt8]]] = []       // [row][col][pixel] alpha
    private var hoverMask: [UInt8] = []       // 交互判定用"站姿轮廓"（行 0 全部帧并集）
    private var timer: Timer?

    private(set) var currentImage: NSImage?
    private var currentRow = -1
    private var currentCol = -1
    private var lastTick: CFTimeInterval = 0
    private var startTime: CFTimeInterval = 0

    // 动画序列：[(列, 每帧秒数)]
    private let IDLE_SEQ: [(Int, Double)] = [(0, 0.28), (1, 0.11), (2, 0.11), (3, 0.14), (4, 0.14), (5, 0.32)]
    private let JUMP_SEQ: [(Int, Double)] = [(0, 0.14), (1, 0.14), (2, 0.14), (3, 0.14), (4, 0.28)]
    private let WAVE_SEQ: [(Int, Double)] = [(0, 0.14), (1, 0.14), (2, 0.14), (3, 0.28)]
    private let RUN_SEQ:  [(Int, Double)] = [(0, 0.12), (1, 0.12), (2, 0.12), (3, 0.12), (4, 0.12), (5, 0.12), (6, 0.12), (7, 0.22)]
    private let WORK_SEQ: [(Int, Double)] = [(0, 0.12), (1, 0.12), (2, 0.12), (3, 0.12), (4, 0.12), (5, 0.22)]

    // 动画播放状态
    private var animKey = ""
    private var animElapsed = 0.0
    private var onceKind = ""                 // "", "wave", "jump"
    private var onceRepeatsLeft = 0
    private var pendingOnce = ""

    // 交互状态
    private var wasHovering = false
    private var lookUntil = 0.0
    private var lastLookDir = -1
    private var dragging = false
    private var dragRight = true
    private var dragPrevX: CGFloat = 0

    // Claude Code 状态
    private var workState = "idle"
    private var lastOnceTS = 0.0
    private var statePollAcc = 0.0

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
    private var aiBusy = false

    // ---------- 吩咐记录（持久保存，可随时查看）----------
    private struct TaskRecord: Codable {
        let t: Double
        let role: String   // "user" / "roxy"
        let text: String
    }
    private var taskHistory: [TaskRecord] = []
    private var historyWindow: NSWindow?

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
    }
    private func saveTaskHistory() {
        if taskHistory.count > 500 { taskHistory.removeFirst(taskHistory.count - 500) }
        if let data = try? JSONEncoder().encode(taskHistory) {
            try? data.write(to: URL(fileURLWithPath: PetController.historyFilePath()))
        }
    }
    private func appendHistory(role: String, text: String) {
        taskHistory.append(TaskRecord(t: Date().timeIntervalSince1970, role: role, text: text))
        saveTaskHistory()
        refreshHistoryWindow()
    }
    private func historyFullText() -> String {
        guard !taskHistory.isEmpty else { return "（还没有吩咐过事情哦。\n\n在菜单里选「吩咐洛琪希做事」，把任务交给我吧。）" }
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        var parts: [String] = []
        for r in taskHistory.reversed() {
            let who = (r.role == "user") ? "你" : "洛琪希"
            parts.append("▸ " + df.string(from: Date(timeIntervalSince1970: r.t)) + "　" + who + "：\n" + r.text)
        }
        return parts.joined(separator: "\n\n────────────────────\n\n")
    }
    private func refreshHistoryWindow() {
        if let w = historyWindow, w.isVisible,
           let scroll = w.contentView as? NSScrollView,
           let tv = scroll.documentView as? NSTextView {
            tv.string = historyFullText()
        }
    }
    @objc private func showTaskHistory() {
        if historyWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "洛琪希 · 吩咐记录"
            w.isReleasedWhenClosed = false
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 440))
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = NSFont.systemFont(ofSize: 13)
            tv.textContainerInset = NSSize(width: 12, height: 12)
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 440))
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            scroll.documentView = tv
            w.contentView = scroll
            w.center()
            historyWindow = w
        }
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
        guard loadAtlas() else {
            NSLog("RoxyPet: failed to load spritesheet")
            NSApp.terminate(nil)
            return
        }
        setupWindow()
        loadSpeechExtras()
        loadTaskHistory()
        startTime = CACurrentMediaTime()
        show(row: 0, col: 0)
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

    private func loadAtlas() -> Bool {
        guard let path = Bundle.main.path(forResource: "spritesheet", ofType: "png"),
              let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }

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
                guard let cell = ctx.makeImage() else { return false }
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
            frames.append(rowFrames)
            masks.append(rowMasks)
        }
        // 悬停/点击判定用"站姿轮廓"：行 0（idle）全部帧的并集，避免动画帧变化导致判定抖动
        var hm = [UInt8](repeating: 0, count: CELL_W * CELL_H)
        for m in masks[0] {
            for i in 0..<(CELL_W * CELL_H) { hm[i] = max(hm[i], m[i]) }
        }
        hoverMask = hm
        return true
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
        guard window != nil, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
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
        let path = NSTemporaryDirectory() + "洛琪希接续会话.command"
        let script = "#!/bin/bash\ncd \"$HOME\"\nexec claude --resume \(sid)\n"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } catch {
            NSLog("RoxyPet: resume command failed: \(error)")
        }
    }

    private func updateBubblePosition() {
        guard let pet = window, let bub = bubbleWindow, bubbleVisible else { return }
        let pf = pet.frame
        var x = pf.midX - bub.frame.width / 2
        var y = pf.maxY + 6
        if let scr = NSScreen.main ?? NSScreen.screens.first {
            let vf = scr.visibleFrame
            x = min(max(x, vf.minX + 6), vf.maxX - bub.frame.width - 6)
            if y + bub.frame.height > vf.maxY - 6 {
                y = pf.minY - bub.frame.height - 6   // 上方放不下 → 放下方
            }
        }
        bub.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // ---------- 事件钩子 ----------
    func dragStarted(atMouseX x: CGFloat) {
        dragging = true
        dragPrevX = x
        lastInteractAt = CACurrentMediaTime()
        if Double.random(in: 0..<1) < 0.12 { speak(randomOf(DRAG_LINES)) }
    }

    func dragEnded() {
        dragging = false
        if !pendingOnce.isEmpty {
            let k = pendingOnce
            pendingOnce = ""
            startOnce(k)
        }
    }

    func startOnce(_ kind: String) {
        if dragging {
            pendingOnce = kind
            return
        }
        onceKind = kind
        onceRepeatsLeft = (kind == "jump") ? 1 : WAVE_REPEAT
    }

    func triggerWave() { startOnce("wave") }
    func triggerJump() { startOnce("jump") }

    // ---------- 主循环 ----------
    private func tick() {
        let now = CACurrentMediaTime()
        if lastTick == 0 { lastTick = now }
        let dt = min(now - lastTick, 0.25)
        lastTick = now
        guard let win = window else { return }

        pollClaudeState(dt: dt)
        pollSchedules(now: now, dt: dt)

        // 情绪维护（本地）：久未互动 → lonely；被连续摸头 → shy（限时）
        if lastInteractAt == 0 { lastInteractAt = now }
        if mood == .shy {
            if now > moodUntil { mood = .calm }
        } else {
            mood = (now - lastInteractAt > 900) ? .lonely : .calm
        }

        // 悬停边沿：进入=被摸一下；移开 → 开启跟随窗口
        let hovering = isHovering()
        if hovering && !wasHovering { onPetted(now: now) }
        if wasHovering && !hovering { lookUntil = now + LOOK_WINDOW_SECONDS }
        wasHovering = hovering
        // 注视刚结束（到点）：小概率说一句
        if lookUntil > 0 && now >= lookUntil {
            lookUntil = 0
            if !hovering && !dragging && Double.random(in: 0..<1) < 0.2 {
                speak(randomOf(LOOK_END_LINES))
            }
        }

        // 拖动方向判定
        if dragging {
            let mx = NSEvent.mouseLocation.x
            let d = mx - dragPrevX
            if d > 0.3 { dragRight = true }
            else if d < -0.3 { dragRight = false }
            dragPrevX = mx
        }

        // ---- 显示决策（优先级从高到低）----
        if onceRepeatsLeft <= 0 { onceKind = "" }

        var key = ""
        var seqRow = 0
        var seq: [(Int, Double)]? = nil
        var loop = true
        var lookDirNow: Int? = nil

        if dragging {
            key = dragRight ? "runR" : "runL"
            seqRow = dragRight ? 1 : 2
            seq = RUN_SEQ
        } else if !onceKind.isEmpty {
            key = "once-" + onceKind
            seqRow = (onceKind == "jump") ? 4 : 3
            seq = (onceKind == "jump") ? JUMP_SEQ : WAVE_SEQ
            loop = false
        } else if hovering {
            key = "hover"
            seqRow = 4
            seq = JUMP_SEQ
        } else if now < lookUntil {
            key = "look"
            lookDirNow = dirToMouse()
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
            animElapsed += dt
            let total = seq.reduce(0) { $0 + $1.1 }
            if animElapsed >= total {
                if loop {
                    animElapsed = animElapsed.truncatingRemainder(dividingBy: total)
                } else {
                    onceRepeatsLeft -= 1
                    if onceRepeatsLeft > 0 {
                        animElapsed -= total
                    } else {
                        animElapsed = 0
                    }
                }
            }
            var acc = 0.0
            var idx = seq.count - 1
            for (i, fr) in seq.enumerated() { acc += fr.1; if animElapsed < acc { idx = i; break } }
            show(row: seqRow, col: seq[idx].0)
        } else if let d = lookDirNow {
            lastLookDir = d
            let rc = dirToRowCol(d)
            show(row: rc.row, col: rc.col)
            maybeDirSpeak(dir: d, now: now)
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

    // ---------- 行为调度：打招呼 / 整点 / 闲聊 / 电池 ----------
    private func pollSchedules(now: CFTimeInterval, dt: Double) {
        // 打招呼
        if !greeted && now - startTime > GREET_DELAY {
            greeted = true
            speak(randomOf(GREETINGS))
            triggerWave()
        }
        // 整点报时
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        if let h = comps.hour, let m = comps.minute, m == 0, h != lastChimeHour {
            lastChimeHour = h
            let quiet = h >= CHIME_QUIET_FROM || h < CHIME_QUIET_TO
            if !quiet {
                speak(hourlyLine(h))
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
            var level = -1
            if let r = s.range(of: #"(\d+)%"#, options: .regularExpression) {
                level = Int(s[r].dropLast()) ?? -1
            }
            let charging = s.contains("charging") || s.contains("charged") || s.contains("AC Power")
            DispatchQueue.main.async { self?.applyBattery(level: level, charging: charging) }
        }
    }

    private func applyBattery(level: Int, charging: Bool) {
        guard level >= 0 else { return }
        battLevel = level
        battCharging = charging
        if charging {
            battWarnStep = 0
            if level >= 100 && !battFullWarned {
                battFullWarned = true
                speak(randomOf(BATTERY_FULL))
                triggerWave()
            }
            if level < 95 { battFullWarned = false }
        } else {
            battFullWarned = false
            if level <= 10 && battWarnStep < 2 {
                battWarnStep = 2
                speak(randomOf(BATTERY_10))
                triggerJump()
            } else if level <= 20 && battWarnStep < 1 {
                battWarnStep = 1
                speak(randomOf(BATTERY_20))
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
        let path = NSHomeDirectory() + "/.roxy-pet/state"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return }
        let st = lines[0]
        let ts = lines.count > 1 ? (Double(lines[1]) ?? 0) : 0
        let nowEpoch = Date().timeIntervalSince1970
        switch st {
        case "working":
            workState = (nowEpoch - ts < WORK_TIMEOUT_SECONDS) ? "working" : "idle"
        case "idle":
            workState = "idle"
        case "done":
            workState = "idle"
            if ts > lastOnceTS {
                lastOnceTS = ts
                if !aiBusy {
                    // 她转派的任务结果由 runClaudeTask 统一展示，避免重复
                    triggerWave()
                    speakDoneReport()
                }
            }
        case "notice":
            workState = "idle"
            if ts > lastOnceTS {
                lastOnceTS = ts
                triggerWave()
                speak(randomOf(NOTICE_LINES))
            }
        default:
            break
        }
    }

    // 完工播报：优先转述 Claude 的实际回复摘要（30 秒内新鲜的），否则用台词库
    private func speakDoneReport() {
        let rp = NSHomeDirectory() + "/.roxy-pet/last_reply"
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
        speak(randomOf(DONE_LINES))
    }

    // ---------- 本地台词路由（情境/情绪；零 token，纯逻辑判断）----------
    private func onPetted(now: CFTimeInterval) {
        lastInteractAt = now
        if now - lastPetAt > 120 { petStreak = 0 }
        lastPetAt = now
        petStreak += 1
        if petStreak >= 4 && mood != .shy {
            mood = .shy
            moodUntil = now + 180
        }
        if Double.random(in: 0..<1) < 0.15 { speak(randomOf(HOVER_LINES)) }
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
        speak(randomOf(DIR_LINES[slot]))
    }

    private func pickChatLine() -> String {
        let comps = Calendar.current.dateComponents([.hour, .weekday], from: Date())
        let h = comps.hour ?? 12
        let wd = comps.weekday ?? 2
        var pool: [String] = []
        if h >= 23 || h < 5 { pool += NIGHT_LINES }
        else if h >= 5 && h < 11 { pool += MORNING_LINES }
        else if h >= 17 { pool += EVENING_LINES }
        else { pool += DAY_LINES }
        if wd == 1 || wd == 7 { pool += WEEKEND_LINES } else { pool += WORKDAY_LINES }
        pool += CHAT_LINES
        switch mood {
        case .shy: pool += HOVER_LINES
        case .lonely: pool += LONELY_LINES
        case .calm: break
        }
        return pool.randomElement() ?? randomOf(CHAT_LINES)
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
    @objc private func sayLocal() {
        let pool = CHAT_LINES.filter { $0 != lastSpokenLine }
        let line = pool.randomElement() ?? randomOf(CHAT_LINES)
        lastSpokenLine = line
        triggerWave()
        speak(line)
    }

    // ---------- 看屏幕（透视魔法）：截图 → 本地 LM Studio 视觉模型 → 洛琪希口吻评论；全程不出本机 ----------
    @objc private func lookAtScreen() {
        if aiBusy {
            speak("……我还在忙上一件事，请稍等一下哦。")
            return
        }
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.roxy-pet/peek-retry")
        if !CGPreflightScreenCaptureAccess() {
            if !requestScreenPermission() { return }
        }
        aiBusy = true
        speak("嗯……让我用透视魔法看一眼。", seconds: 8)
        DispatchQueue.global().async { [weak self] in
            let result = PetController.screenPeek()
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
            alert.messageText = "洛琪希需要「屏幕录制」权限"
            if checkFailed {
                alert.informativeText = "还没检测到授权——如果刚刚勾选，可能需要重启我才能识别。可以点「帮我重启再看」，或回到「打开设置」再确认一下勾选。"
            } else {
                alert.informativeText = "macOS 要求应用截屏前必须先获得授权。\n\n请点「打开设置」→ 在「屏幕录制」里勾选「洛琪希桌宠」（如有多条旧记录，请先移除旧条目）→ 回来点「检查并继续」。"
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

    private static func screenPeek() -> String {
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
        let sys = "你扮演《无职转生》的洛琪希·米格路迪亚：穿越到现实世界、当小萌老师桌宠的米格路德族水圣级魔术师。你正用「透视魔法」看到主人的电脑屏幕。请用她礼貌、认真、偶尔好奇或害羞的口吻，用 1~2 句中文评论屏幕上的内容（40 字以内）；可以自然联系故乡的人、事、物（如希露菲、魔大陆、魔法大学，或把屏幕上的东西比作魔导书、魔术阵）；不要提及「鲁迪乌斯」这个名字；只输出台词本身，不要引号、不要 emoji、不要解释。"
        let userText = "这是小萌老师的屏幕截图。请按人设评论。"
        // 主路径：接入的 API（Anthropic 兼容、支持视觉）
        if let t = askVisionAPI(system: sys, userText: userText, imageB64: b64) { return t }
        // 备选：本地 LM Studio（若在运行且有视觉模型）
        if let t = askLMStudio(system: sys, userText: userText, imageB64: b64) { return t }
        return "唔……透视魔法一时连不上呢。稍后再试一次好吗？"
    }

    // 主路径：走已接入的 API（从 ~/.claude/settings.json 读取端点与凭证）
    private static func askVisionAPI(system: String, userText: String, imageB64: String) -> String? {
        guard let cfgData = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json"),
              let cfg = (try? JSONSerialization.jsonObject(with: cfgData)) as? [String: Any] else {
            dbg("api: settings unreadable")
            return nil
        }
        guard let env = cfg["env"] as? [String: String] else {
            dbg("api: env cast failed")
            return nil
        }
        guard let key = env["ANTHROPIC_AUTH_TOKEN"], !key.isEmpty,
              let baseStr = env["ANTHROPIC_BASE_URL"],
              let base = URL(string: baseStr) else {
            dbg("api: creds failed")
            return nil
        }
        var model = env["ANTHROPIC_MODEL"] ?? "deepseek-flash"
        if let r = model.range(of: "[") { model = String(model[..<r.lowerBound]) }
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

    // ---------- 单击她 / 菜单：吩咐任务 → 转给 Claude Code 执行（专属持久会话）----------
    func petClicked() { askClaudeCode() }

    @objc private func askClaudeCode() {
        if aiBusy {
            speak("我还在忙上一件事……请稍等一下哦。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "吩咐洛琪希"
        alert.informativeText = "输入任务或问题，洛琪希会转达给 Claude Code 执行，再把结果带回来。"
        alert.addButton(withTitle: "交给洛琪希")
        alert.addButton(withTitle: "查看记录")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "例如：看看我的下载文件夹里有什么"
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeFirstResponder(input)
        let resp = alert.runModal()
        if resp == .alertSecondButtonReturn { showTaskHistory(); return }
        guard resp == .alertFirstButtonReturn else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runClaudeTask(text)
    }

    private func runClaudeTask(_ text: String) {
        aiBusy = true
        speak("嗯……交给我吧。", seconds: 6)
        appendHistory(role: "user", text: text)
        let d = UserDefaults.standard
        let key = "roxySessionId"
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
            let result = PetController.runClaude(prompt: text, sessionId: sid, isFirst: isFirst)
            DispatchQueue.main.async {
                self?.aiBusy = false
                if let line = result, !line.isEmpty {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(line, forType: .string)
                    self?.appendHistory(role: "roxy", text: line)
                    let summary = line.count > 110 ? String(line.prefix(110)) + "…（点击气泡可复制全文 / 接续会话）" : line
                    self?.speak(summary, seconds: 25, fullText: line, resumeSid: sid)
                } else {
                    let fail = randomOf(AI_FAIL)
                    self?.appendHistory(role: "roxy", text: "（\(fail)）")
                    self?.speak(fail)
                }
            }
        }
    }

    // ---------- AI 点选发言（默认不用；点选才消耗大模型额度）----------
    @objc private func askAI() {
        if aiBusy { return }
        aiBusy = true
        speak(randomOf(AI_THINKING), seconds: 8)
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        let timeStr = df.string(from: Date())
        let prompt = """
        你现在扮演《无职转生》里的洛琪希·米格路迪亚：蓝发双辫的米格路德族、水圣级魔术师、当过许多年家庭教师；认真、温柔、礼貌、容易害羞，说话轻声带教学式口吻。她如今穿越到了现实世界，当小萌老师 Mac 桌面上的桌宠。
        请用她的口吻对主人说一句简短的问候或闲话（10~40 字），要求：
        1. 多用《无职转生》世界观元素：自然地提到故乡的人物（希露菲、艾莉丝、保罗、基列奴、瑞杰路德、札诺巴等）、地名（魔大陆、拉诺亚魔法大学、布耶纳村、米里斯等）、事物（魔杖、魔导书、咏唱、魔力、冒险者公会等），与现实桌面上的见闻对比或联想；
        2. 口吻贴合原作：礼貌、温柔、认真，偶尔害羞或小自豪；不傲娇、不毒舌、不用网络用语；
        3. 不要提及「鲁迪乌斯」这个名字；
        4. 现在是 \(timeStr)。
        只输出台词本身，不要引号、不要解释、不要 emoji。
        """
        DispatchQueue.global().async { [weak self] in
            var result = PetController.runClaude(prompt: prompt)
            if let r = result, let first = r.split(separator: "\n").first { result = String(first) }
            DispatchQueue.main.async {
                self?.aiBusy = false
                if let line = result, !line.isEmpty {
                    self?.speak(line)
                } else {
                    self?.speak(randomOf(AI_FAIL))
                }
            }
        }
    }

    private static func findClaude() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !s.isEmpty && FileManager.default.isExecutableFile(atPath: s) { return s }
        return nil
    }

    private static func runClaude(prompt: String, sessionId: String? = nil, isFirst: Bool = false) -> String? {
        guard let path = findClaude() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        if let sid = sessionId {
            p.arguments = isFirst ? ["-p", "--session-id", sid, prompt] : ["-p", "--resume", sid, prompt]
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
        if row == currentRow && col == currentCol { return }
        currentRow = row
        currentCol = col
        currentImage = frames[row][col]
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

    // ---------- 右键菜单 ----------
    func showContextMenu(with event: NSEvent) {
        guard let v = petView else { return }
        let menu = NSMenu()
        let say = NSMenuItem(title: "让洛琪希说句话（本地·零消耗）", action: #selector(sayLocal), keyEquivalent: "")
        say.target = self
        menu.addItem(say)
        let task = NSMenuItem(title: "吩咐洛琪希做事（转给 Claude Code）", action: #selector(askClaudeCode), keyEquivalent: "")
        task.target = self
        menu.addItem(task)
        let hist = NSMenuItem(title: "查看吩咐记录", action: #selector(showTaskHistory), keyEquivalent: "")
        hist.target = self
        menu.addItem(hist)
        let look = NSMenuItem(title: "看看屏幕上是什么（透视魔法）", action: #selector(lookAtScreen), keyEquivalent: "")
        look.target = self
        menu.addItem(look)
        let ai = NSMenuItem(title: "让洛琪希想句话（用大模型）", action: #selector(askAI), keyEquivalent: "")
        ai.target = self
        menu.addItem(ai)
        let reset = NSMenuItem(title: "回到屏幕右下角", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出洛琪希", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: v)
    }

    @objc private func resetPosition() { placeDefaultPosition() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

// ---------- 入口 ----------
let app = NSApplication.shared
let controller = PetController()
app.delegate = controller
app.run()
