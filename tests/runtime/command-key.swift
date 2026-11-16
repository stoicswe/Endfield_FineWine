// Sends Command plus one key (a macOS virtual key code) to one process only, wherever it is on
// screen: command-key <pid> <keycode>. Needs the Accessibility permission for whatever runs it.
import CoreGraphics
import Foundation
let pid = pid_t(CommandLine.arguments[1])!, key = CGKeyCode(UInt16(CommandLine.arguments[2])!)
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
    e.flags = .maskCommand
    e.postToPid(pid)
    usleep(80000)
}
