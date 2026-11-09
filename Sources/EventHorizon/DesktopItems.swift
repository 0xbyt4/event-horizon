import AppKit
import HorizonCore

/// Reads the positions of the file icons on the desktop from Finder.
///
/// The lookup runs `osascript` in a short-lived child process, so the app does not keep
/// the AppleScript runtime in memory. The first lookup asks the user for permission
/// to control Finder (System Settings > Privacy & Security > Automation).
enum DesktopItems {
    enum LookupError: Error {
        case notAuthorized
        case failed
    }

    private static let script = """
        tell application "Finder"
            set itemURLs to URL of every item of desktop
            set itemPositions to desktop position of every item of desktop
        end tell
        set output to ""
        repeat with i from 1 to count of itemURLs
            set itemPosition to item i of itemPositions
            set output to output & item i of itemURLs & tab & item 1 of itemPosition & tab & item 2 of itemPosition & linefeed
        end repeat
        return output
        """

    /// False when the user hides desktop icons, so the hole never takes items the user cannot see.
    static var areVisible: Bool {
        if preference("CreateDesktop", "com.apple.finder") == false { return false }
        let stageManager = preference("GloballyEnabled", "com.apple.WindowManager") == true
        let hidden = preference(stageManager ? "HideDesktop" : "StandardHideDesktopIcons", "com.apple.WindowManager")
        return hidden != true
    }

    private static func preference(_ key: String, _ domain: String) -> Bool? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool
    }

    static func fetch() async -> Result<[DesktopItem], LookupError> {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
              let mainScreenHeight = NSScreen.screens.first?.frame.height else { return .failure(.failed) }

        return await Task.detached(priority: .userInitiated) { () -> Result<[DesktopItem], LookupError> in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return .failure(.failed)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                // -1743: the user did not allow the app to control Finder.
                return .failure(errorText.contains("-1743") ? .notAuthorized : .failed)
            }
            let text = String(decoding: data, as: UTF8.self)
            return .success(DesktopSweep.parse(text, mainScreenHeight: mainScreenHeight, desktopFolder: desktop))
        }.value
    }
}
