// GariPet — 가리의 몸. 화면에 상주하는 픽셀 펫 (CodexPet 문법).
// 원칙: 표시하는 모든 상태는 실제 상태다 — 자는 모습 = 가리가 진짜 유휴라는 뜻.
// 본체와 분리: 이 앱이 죽어도 가리(수집·증류·보고)는 무사하다.
// 빌드: swiftc -O -o gari-pet GariPet.swift
import AppKit

// ---------------------------------------------------------------- 가리 상태 읽기

enum GariMood {
    case sleeping   // 유휴 — 스윕 사이 (진짜 자는 중)
    case working    // sweep.lock 존재 — 지금 정리 중
    case report     // 안 읽은 보고/결재 있음
    case alert      // 파이프라인 이상 (스윕 부재·실패 누적)
}

struct GariState {
    var mood: GariMood = .sleeping
    var badge: Int = 0

    static func read() -> GariState {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let gari = home.appendingPathComponent("gari")
        let store = gari.appendingPathComponent("store")
        var s = GariState()
        let fm = FileManager.default

        // 이상: health의 last_sweep이 스윕 주기의 3배 넘게 침묵 → 죽었을 가능성 (fail-loud 시각화)
        var sweepStale = true
        if let data = try? Data(contentsOf: store.appendingPathComponent("health.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let last = json["last_sweep"] as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            if let d = fmt.date(from: last), Date().timeIntervalSince(d) < 30 * 60 {
                sweepStale = false
            }
        }

        // 결재·보고 배지
        if let data = try? Data(contentsOf: gari.appendingPathComponent("pending-approvals.json")),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            s.badge = arr.count
        }
        // 오늘 보고서가 있고 아직 안 열었으면 배지 +1
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        let reportPath = gari.appendingPathComponent("reports/\(today).md").path
        let seenMarker = gari.appendingPathComponent("pet/seen-\(today)").path
        let reportUnread = fm.fileExists(atPath: reportPath) && !fm.fileExists(atPath: seenMarker)
        if reportUnread { s.badge += 1 }

        if sweepStale {
            s.mood = .alert
        } else if fm.fileExists(atPath: store.appendingPathComponent("sweep.lock").path) {
            s.mood = .working
        } else if s.badge > 0 {
            s.mood = .report
        } else {
            s.mood = .sleeping
        }
        return s
    }
}

// ---------------------------------------------------------------- 픽셀 스프라이트

// 문자 → 색: .=투명 B=몸 D=몸그늘 W=흰자 K=눈동자 M=입 Z=포인트(민트) R=경고(주황빨강)
let SPRITES: [String: [String]] = [
    // 자는 가리 — 눈 감고 숨쉬기 (2프레임은 코드에서 몸통 1px 스쿼시로)
    "sleep": [
        ".....BBBBB.....",
        "...BBBBBBBBB...",
        "..BBBBBBBBBBB..",
        ".BBBBBBBBBBBBB.",
        ".BBB..BBB..BBB.",   // 감은 눈 (가로선)
        ".BBBBBBBBBBBBB.",
        ".BBBBB.M.BBBBB.",
        "..BBBBBBBBBBB..",
        "...BBBBBBBBB...",
        "....DD...DD....",
    ],
    // 깨어있음/보고 — 눈 뜸
    "awake": [
        ".....BBBBB.....",
        "...BBBBBBBBB...",
        "..BBBBBBBBBBB..",
        ".BBBWWBBBWWBBB.",
        ".BBBWKBBBWKBBB.",   // 뜬 눈
        ".BBBBBBBBBBBBB.",
        ".BBBBB.M.BBBBB.",
        "..BBBBBBBBBBB..",
        "...BBBBBBBBB...",
        "....DD...DD....",
    ],
    // 일하는 중 — 팔 올리고 눈 반짝
    "work": [
        ".Z...BBBBB...Z.",
        ".ZB.BBBBBBB.BZ.",
        "..BBBBBBBBBBB..",
        ".BBBWWBBBWWBBB.",
        ".BBBWKBBBWKBBB.",
        ".BBBBBBBBBBBBB.",
        ".BBBB.MMM.BBBB.",   // 벌린 입 (집중)
        "..BBBBBBBBBBB..",
        "...BBBBBBBBB...",
        "....DD...DD....",
    ],
    // 이상 — 놀란 표정
    "alert": [
        ".....RRRRR.....",
        "...RRRRRRRRR...",
        "..RRRRRRRRRRR..",
        ".RRRWWRRRWWRRR.",
        ".RRRWKRRRWKRRR.",
        ".RRRRRRRRRRRRR.",
        ".RRRR.MMM.RRRR.",
        "..RRRRRRRRRRR..",
        "...RRRRRRRRR...",
        "....DD...DD....",
    ],
]

let PALETTE: [Character: NSColor] = [
    "B": NSColor(calibratedWhite: 0.22, alpha: 1.0),          // 몸: 차콜
    "D": NSColor(calibratedWhite: 0.15, alpha: 1.0),          // 발 그늘
    "W": NSColor(calibratedWhite: 0.97, alpha: 1.0),          // 흰자
    "K": NSColor(calibratedWhite: 0.05, alpha: 1.0),          // 눈동자
    "M": NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.55, alpha: 1.0), // 입
    "Z": NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.72, alpha: 1.0), // 포인트 민트
    "R": NSColor(calibratedRed: 0.90, green: 0.35, blue: 0.30, alpha: 1.0), // 경고
]

// ---------------------------------------------------------------- 펫 뷰

final class PetView: NSView {
    var state = GariState()
    var frameTick = 0          // 숨쉬기·zzz 애니메이션 프레임
    let cell: CGFloat = 6      // 픽셀 크기

    override var acceptsFirstResponder: Bool { true }

    func spriteName() -> String {
        switch state.mood {
        case .sleeping: return "sleep"
        case .working:  return "work"
        case .report:   return "awake"
        case .alert:    return "alert"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rows = SPRITES[spriteName()] else { return }
        let squash: CGFloat = (state.mood == .sleeping && frameTick % 2 == 0) ? 1 : 0
        let cols = CGFloat(rows[0].count)
        let originX = (bounds.width - cols * cell) / 2
        let originY: CGFloat = 14

        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                guard let color = PALETTE[ch] else { continue }
                color.setFill()
                let y = originY + CGFloat(rows.count - 1 - r) * cell - (r < 3 ? squash : 0)
                NSRect(x: originX + CGFloat(c) * cell, y: y,
                       width: cell, height: cell).fill()
            }
        }
        // zzz (잘 때만, 깜빡이며)
        if state.mood == .sleeping && frameTick % 4 < 2 {
            let z = "z" + (frameTick % 4 == 0 ? "z" : "")
            (z as NSString).draw(at: NSPoint(x: originX + cols * cell - 8, y: originY + CGFloat(SPRITES["sleep"]!.count) * cell + 2),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                                 .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 0.9)])
        }
        // 배지
        if state.badge > 0 {
            let bx = originX + cols * cell - 6, by = originY + CGFloat(SPRITES["sleep"]!.count) * cell - 4
            let badge = NSRect(x: bx, y: by, width: 16, height: 16)
            NSColor(calibratedRed: 0.90, green: 0.35, blue: 0.30, alpha: 1).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let n = "\(min(state.badge, 9))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
            let sz = n.size(withAttributes: attrs)
            n.draw(at: NSPoint(x: badge.midX - sz.width / 2, y: badge.midY - sz.height / 2), withAttributes: attrs)
        }
    }

    // 클릭 = 보고 열기 (읽음 처리), 드래그 = 이동, 우클릭 = 메뉴
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)   // 드래그 시작이면 이동
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1 { openReport() }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "보고 열기", action: #selector(menuReport), keyEquivalent: "").target = self
        menu.addItem(withTitle: "상태 확인 (gari status)", action: #selector(menuStatus), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "가리 펫 종료 (본체는 계속 돎)", action: #selector(menuQuit), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func gariDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("gari")
    }

    @objc func menuReport() { openReport() }

    func openReport() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        let gari = gariDir()
        // 읽음 마커 (배지 해제 근거 — 실제로 열었을 때만)
        FileManager.default.createFile(
            atPath: gari.appendingPathComponent("pet/seen-\(today)").path, contents: nil)
        var report = gari.appendingPathComponent("reports/\(today).md")
        if !FileManager.default.fileExists(atPath: report.path) {
            // 오늘 것 없으면 최신 보고
            if let latest = (try? FileManager.default.contentsOfDirectory(
                at: gari.appendingPathComponent("reports"), includingPropertiesForKeys: nil))?
                .filter({ $0.pathExtension == "md" }).sorted(by: { $0.path > $1.path }).first {
                report = latest
            }
        }
        NSWorkspace.shared.open(report)
    }

    @objc func menuStatus() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        let out = gariDir().appendingPathComponent("pet/status-snapshot.txt")
        task.arguments = ["-c", "\(gariDir().path)/bin/gari status > \(out.path) 2>&1; open -e \(out.path)"]
        try? task.run()
    }

    @objc func menuQuit() { NSApp.terminate(nil) }
}

// ---------------------------------------------------------------- 앱 조립

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: PetView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = NSSize(width: 120, height: 100)
        // 저장된 위치 복원 (기본: 우하단, 독 위)
        var origin = NSPoint(x: (NSScreen.main?.frame.maxX ?? 1400) - 160,
                             y: (NSScreen.main?.frame.minY ?? 0) + 90)
        let posFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("gari/pet/position.json")
        if let d = try? Data(contentsOf: posFile),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Double],
           let x = j["x"], let y = j["y"] {
            origin = NSPoint(x: x, y: y)
        }

        window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating                       // 항상 위 (코덱스펫 문법)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]  // 모든 데스크톱에
        window.hasShadow = false
        window.isMovableByWindowBackground = true

        view = PetView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        window.orderFrontRegardless()

        // 상태 폴링(가벼운 로컬 파일 읽기)과 애니메이션
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.view.state = GariState.read()
            self.view.needsDisplay = true
        }
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            self.view.frameTick += 1
            self.view.needsDisplay = true
        }
        // 위치 저장 (이동 시)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
            let o = self.window.frame.origin
            let j = ["x": Double(o.x), "y": Double(o.y)]
            if let d = try? JSONSerialization.data(withJSONObject: j) {
                try? d.write(to: posFile)
            }
        }
        view.state = GariState.read()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 독·앱전환기에 안 나타남
let delegate = AppDelegate()
app.delegate = delegate
app.run()
