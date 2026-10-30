import Foundation

enum GrokBotProviderDef: DetectionOnlyProvider {
    static let typeId = "grok-bot"
    static let defaultName = "Grok Bot"
    static let iconSymbol = "sparkles"
    static let dashboardURL: URL? = URL(string: "https://x.ai/bot")

    private static let appPaths = [
        "/Applications/Grok Bot.app",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Grok Bot.app").path,
    ]
    static let detection = DetectionSpec(paths: appPaths)
    static let iconSpec = IconSpec(appBundlePaths: appPaths)
}
