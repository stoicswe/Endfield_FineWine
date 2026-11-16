// Drives one program's menu bar through the accessibility interface, without the mouse and
// whichever app is in front: axmenu <pid> list | press <menu> | pick <menu> <item> | cancel.
// Needs the Accessibility permission for whatever runs it (the terminal).
import ApplicationServices
import Foundation
// axmenu <pid> list | press <index> | cancel
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "trusted" { print(AXIsProcessTrusted() ? "yes" : "no"); exit(0) }
let pid = pid_t(CommandLine.arguments[1])!, cmd = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
guard let bar = attr(app, kAXMenuBarAttribute) else { print("no menu bar reachable"); exit(1) }
let items = (attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
func title(_ e: AXUIElement) -> String { (attr(e, kAXTitleAttribute) as? String) ?? "?" }
if cmd == "list" {
    for (i, item) in items.enumerated() {
        let subs = (attr(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        let entries = subs.flatMap { (attr($0, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }.map(title)
        print(i, title(item), "->", entries)
    }
} else if cmd == "press" {
    let r = AXUIElementPerformAction(items[Int(CommandLine.arguments[3])!], kAXPressAction as CFString)
    print("press result", r.rawValue)
} else if cmd == "pick" {
    let menu = items[Int(CommandLine.arguments[3])!]
    let subs = (attr(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    let entries = subs.flatMap { (attr($0, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    if let e = entries.first(where: { title($0) == CommandLine.arguments[4] }) {
        let enabled = (attr(e, kAXEnabledAttribute) as? Bool) ?? false
        print("pick", CommandLine.arguments[4], "enabled", enabled, "result", AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue)
    } else { print("no such item") }
} else if cmd == "cancel" {
    for item in items { AXUIElementPerformAction(item, kAXCancelAction as CFString) }
    print("cancelled")
}
