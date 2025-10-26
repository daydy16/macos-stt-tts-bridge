import Foundation

struct Config {
    let port: Int
    let bindHost: String
    let authToken: String?
    let defaultLang: String
    let offlineOnly: Bool

    init(env: [String:String] = ProcessInfo.processInfo.environment) {
        port = Int(env["PORT"] ?? "") ?? 8787
        bindHost = env["BIND_HOST"] ?? "127.0.0.1"
        authToken = env["AUTH_TOKEN"]
        defaultLang = env["DEFAULT_LANG"] ?? "de-DE"
        offlineOnly = (env["OFFLINE_ONLY"] ?? "false").lowercased() == "true"
    }
}
