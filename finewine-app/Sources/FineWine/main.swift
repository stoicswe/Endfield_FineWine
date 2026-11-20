import Foundation
import FineWineCore

// FineWine is started two ways: as the menu bar app, and by its Steam tool's script as
// `FineWine --steam-run <verb> <program> …`, which starts one game for the Mac Steam client
// and ends when the game does. That second way opens no window and no menu bar item.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--steam-run" {
    exit(SteamRunCommand.run(Array(arguments.dropFirst())))
}
FineWineApp.main()
