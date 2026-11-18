// Switches to the app with the given process id and back to the app that was in front,
// a number of times, half a second apart. Used with idle-window.c.
// Usage: swift activate.swift <pid> [times]
import AppKit

let pid = pid_t(CommandLine.arguments[1])!
let times = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 3
guard let target = NSRunningApplication(processIdentifier: pid) else { print("activate: no app with pid \(pid)"); exit(1) }
let front = NSWorkspace.shared.frontmostApplication
for _ in 0..<times {
    target.activate(options: [])
    Thread.sleep(forTimeInterval: 0.6)
    front?.activate(options: [])
    Thread.sleep(forTimeInterval: 0.6)
}
print("activate: done, target was active \(target.isActive), front restored \(front?.isActive ?? false)")
