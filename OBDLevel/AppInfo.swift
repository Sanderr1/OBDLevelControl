import Foundation

/// Hand-bumped stamp shown in Diagnostik. The point is to tell two installs
/// apart from one screenshot: it has happened that an old .ipa was sideloaded,
/// and the only visible difference was rows that were missing.
enum AppInfo {
    static let build = "B12 · sänk båda"
}
