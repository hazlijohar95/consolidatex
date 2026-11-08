import Foundation

/// Keeps a copy of Consolidatex.app in ~/Applications in step with the acc that ships inside
/// it. A Homebrew formula builds the app inside its keg, where Finder, Spotlight and Login
/// Items can't rely on it (the path changes every upgrade), so `acc setup` copies it out.
public enum AppInstall {
    public static let name = "Consolidatex.app"

    public enum Status: Equatable, Sendable {
        /// This acc is not running from an app bundle (a bare `swift build`), so there is nothing to install.
        case notBundled
        /// The app this acc ships in is where it belongs.
        case inPlace(String)
        case missing(bundle: String)
        case outdated(installed: String, version: String?, bundle: String)
        case current(String)
    }

    /// The .app that contains `executable`, through symlinks such as Homebrew's bin link.
    public static func bundle(containing executable: String) -> String? {
        appBundle(around: canonical(executable))
    }

    /// The outermost app bundle in a path, so a helper app inside another reads as the outer one.
    static func appBundle(around path: String) -> String? {
        path.range(of: ".app/Contents/").map { String(path[..<$0.lowerBound]) + ".app" }
    }

    public static func version(of app: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: app + "/Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["CFBundleShortVersionString"] as? String
    }

    public static func status(executable: String, home: String = userHome()) -> Status {
        guard let bundle = bundle(containing: executable) else { return .notBundled }
        let installed = [home + "/Applications/" + name, "/Applications/" + name]
        if installed.map(canonical).contains(canonical(bundle)) { return .inPlace(bundle) }
        guard let existing = installed.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return .missing(bundle: bundle)
        }
        let have = version(of: existing)
        return have == version(of: bundle) ? .current(existing) : .outdated(installed: existing, version: have, bundle: bundle)
    }

    /// Copies `bundle` to `destination` (default ~/Applications), replacing an older copy. Returns where it went.
    @discardableResult
    public static func install(_ bundle: String, to destination: String? = nil, home: String = userHome()) throws -> String {
        let target = destination ?? home + "/Applications/" + name
        let fm = FileManager.default
        try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let staging = target + ".installing"
        try? fm.removeItem(atPath: staging)
        try fm.copyItem(atPath: bundle, toPath: staging)
        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
        try fm.moveItem(atPath: staging, toPath: target)
        return target
    }
}
