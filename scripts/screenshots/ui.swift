// ui.swift — tiny CGEvent helper for the screenshot driver: list windows, click, scroll.
// Deliberately has no typing: keystrokes are never PID-scoped and could land in the
// owner's apps. Build: swiftc -O -o scripts/screenshots/ui scripts/screenshots/ui.swift
import Cocoa
import CoreGraphics

func wins() {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        let id = w[kCGWindowNumber as String] as? Int ?? 0
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let title = w[kCGWindowName as String] as? String ?? ""
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print("\(id) \(owner) \"\(title)\" \(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))")
    }
}

func click(_ x: Double, _ y: Double) {
    let p = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func doubleClick(_ x: Double, _ y: Double) {
    let p = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    for state in [1, 2] as [Int64] {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: state)
            e?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
    }
}

func scroll(_ x: Double, _ y: Double, dy: Int32, dx: Int32, steps: Int, gapMs: UInt32) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
    for _ in 0..<steps {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
        usleep(gapMs * 1000)
    }
}

let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "wins": wins()
case "click" where a.count == 4: click(Double(a[2])!, Double(a[3])!)
case "dclick" where a.count == 4: doubleClick(Double(a[2])!, Double(a[3])!)
case "scroll" where a.count == 8: scroll(Double(a[2])!, Double(a[3])!, dy: Int32(a[4])!, dx: Int32(a[5])!, steps: Int(a[6])!, gapMs: UInt32(a[7])!)
default:
    print("usage: ui wins | click X Y | dclick X Y | scroll X Y dy dx steps gapMs")
    exit(1)
}
