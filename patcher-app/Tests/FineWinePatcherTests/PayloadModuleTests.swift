import XCTest
@testable import FineWinePatcher

/// Guards the payload module manifest. The GUI patcher must swap the same core modules as
/// `scripts/swap-into-crossover.sh`, and it must include `wineserver`: stock CrossOver ships an
/// older server whose protocol does not match the patched `ntdll.so`, so leaving it in place makes
/// every wine process die with `wine client error:0: version mismatch …` before any window shows.
/// The payload previously omitted this module, which caused exactly that.
final class PayloadModuleTests: XCTestCase {

    private func destinations(of payloadSubpath: String) -> [String] {
        Payload.modules.filter { $0.payloadSubpath == payloadSubpath }.map(\.crossoverSubpath)
    }

    func testSwapsWineserverAtBothCrossOverPaths() {
        // CrossOver installs the same wineserver binary at two paths; both must be replaced.
        XCTAssertEqual(
            destinations(of: "server/wineserver").sorted(),
            ["CrossOver-Hosted Application/wineserver", "bin/wineserver"].sorted()
        )
    }

    func testSwapsEveryCoreModuleFromTheShellScript() {
        let dests = Set(Payload.modules.map(\.crossoverSubpath))
        for dest in [
            "lib/wine/x86_64-unix/ntdll.so",
            "lib/wine/x86_64-windows/kernel32.dll",
            "lib/wine/x86_64-windows/ntoskrnl.exe",
            "lib/wine/x86_64-windows/lsass.exe",
            "lib/wine/x86_64-windows/wineboot.exe",
            "bin/wineserver",
            "CrossOver-Hosted Application/wineserver",
            "lib64/libMoltenVK.dylib",
        ] {
            XCTAssertTrue(dests.contains(dest), "missing swap destination: \(dest)")
        }
    }
}
