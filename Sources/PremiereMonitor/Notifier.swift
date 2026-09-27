import Foundation

enum Notifier {
    private static let envFile = ("~/htm-rooster/script/config.env" as NSString).expandingTildeInPath

    // Deliberately not cached: this used to cache forever after the first read, so rotating
    // the shared PUSHOVER_TOKEN in that file while Reprise was already running had no effect
    // until Reprise was restarted, with no indication why pushes had started failing. The file
    // is tiny and this is only read when actually sending a notification (at most a handful
    // of times an hour), so re-reading every time costs nothing worth caching for.
    private static func loadEnv() -> [String: String] {
        var result: [String: String] = [:]
        if let contents = try? String(contentsOfFile: envFile, encoding: .utf8) {
            for rawLine in contents.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                result[key] = value
            }
        }
        return result
    }

    /// The credentials that are actually in effect right now: your own, if set
    /// in Settings, otherwise whatever the shared env file resolves to. Used
    /// both to send notifications and to pre-fill the Settings screen so you
    /// can see what's active before you decide to override it.
    static func activeCredentials(override: (token: String?, userKey: String?)) -> (token: String?, userKey: String?) {
        let ownToken = override.token?.trimmingCharacters(in: .whitespaces)
        let ownUser = override.userKey?.trimmingCharacters(in: .whitespaces)
        if let ownToken, !ownToken.isEmpty, let ownUser, !ownUser.isEmpty {
            return (ownToken, ownUser)
        }
        let env = loadEnv()
        return (env["PUSHOVER_TOKEN"], env["PUSHOVER_USER_ANDRE"])
    }

    /// Sends a Pushover notification. `override` is the app's own Settings
    /// value; if either half is empty this falls back to the shared env file
    /// that Reprise originally borrowed its keys from (~/htm-rooster/script/
    /// config.env). Fails silently (with a callback for logging) if neither
    /// source has usable credentials.
    static func send(title: String, message: String,
                     override: (token: String?, userKey: String?) = (nil, nil),
                     onResult: @escaping (Bool, String) -> Void) {
        let (token, user) = activeCredentials(override: override)
        guard let token, !token.isEmpty, let user, !user.isEmpty else {
            onResult(false, "No Pushover credentials — set them in Reprise's Settings, "
                          + "or check \(envFile)")
            return
        }

        var request = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "message", value: message)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                onResult(false, "Pushover error: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                onResult(false, "Pushover returned HTTP \(http.statusCode): \(body)")
                return
            }
            onResult(true, "Pushover notification sent.")
        }.resume()
    }
}
