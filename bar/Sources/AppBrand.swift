import Foundation

/// User-facing name comes from the packaged app. Keep Phonon's data paths and
/// bundle identifier independent so a display-name change preserves settings.
enum AppBrand {
    static let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? "Phonon"
}
