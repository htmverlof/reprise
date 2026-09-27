import Foundation

enum Notifier {
    /// The credentials currently set in Settings. A thin wrapper (rather than reading
    /// `override` directly at each call site) so there's one place to extend this later —
    /// kept trivial on purpose: this used to also fall back to a personal, machine-specific
    /// shared config file, which made no sense once Reprise became something other people
    /// could download too (they'd never have that file, and "Shared (unknown-name)" showing
    /// up in Settings for a brand-new install was just confusing).
    static func activeCredentials(override: (token: String?, userKey: String?)) -> (token: String?, userKey: String?) {
        let token = override.token?.trimmingCharacters(in: .whitespaces)
        let userKey = override.userKey?.trimmingCharacters(in: .whitespaces)
        return (token?.isEmpty == false ? token : nil, userKey?.isEmpty == false ? userKey : nil)
    }

    /// Sends a Pushover notification using the credentials set in Settings. Fails silently
    /// (with a callback for logging) if none are set.
    static func send(title: String, message: String,
                     override: (token: String?, userKey: String?) = (nil, nil),
                     onResult: @escaping (Bool, String) -> Void) {
        let (token, user) = activeCredentials(override: override)
        guard let token, let user else {
            onResult(false, "No Pushover credentials set — add them in Reprise's Settings → Notifications.")
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
