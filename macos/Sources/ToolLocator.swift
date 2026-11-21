import Foundation

/// Auto-discovers `adb` and `scrcpy` across bundled app resources, Apple Silicon Homebrew,
/// Intel Homebrew, Android Studio SDK, and PATH so Bridge works on any Mac.
enum ToolLocator {
    private static let searchDirs: [String] = {
        var dirs: [String] = []
        if let resPath = Bundle.main.resourcePath {
            dirs.append((resPath as NSString).appendingPathComponent("bin"))
        }
        dirs.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Android/sdk/platform-tools"),
            "/usr/bin",
            "/bin"
        ])
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        }
        return dirs.reduce(into: [String]()) { acc, dir in
            if !dir.isEmpty && !acc.contains(dir) { acc.append(dir) }
        }
    }()

    static func resolve(_ binary: String) -> String {
        let fm = FileManager.default
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(binary)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/opt/homebrew/bin/\(binary)"
    }

    static func adbPath() -> String { resolve("adb") }
    static func scrcpyPath() -> String { resolve("scrcpy") }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirs.joined(separator: ":")
        env["ADB"] = adbPath()
        return env
    }
}
