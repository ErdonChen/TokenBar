import Foundation

enum AntigravityProviderDef: DetectionOnlyProvider {
    static let typeId = "antigravity"
    static let defaultName = "Antigravity"
    static let iconSymbol = "sparkles"
    static let dashboardURL: URL? = URL(string: "https://antigravity.google/")

    private static let appPaths = [
        "/Applications/Antigravity.app",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Antigravity.app").path,
    ]
    static let detection = DetectionSpec(paths: appPaths)
    static let iconSpec = IconSpec(appBundlePaths: appPaths)
}
