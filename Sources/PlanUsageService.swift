import Foundation

enum PlanError: Error, Sendable {
    case noCredentials
    case expired
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case parse

    var message: String {
        switch self {
        case .noCredentials: return "No Claude Code login found. Run `claude` in a terminal and sign in once."
        case .expired: return "Login expired and auto-refresh failed. Run `claude` in a terminal to sign in again."
        case .rateLimited: return "Anthropic is rate-limiting usage checks; retrying shortly."
        case .http(let code): return "Usage endpoint returned HTTP \(code)."
        case .network(let msg): return "Network error: \(msg)"
        case .parse: return "Could not parse usage data."
        }
    }
}

/// Reads plan-limit usage (5-hour session / weekly) for the account Claude Code is logged into.
///
/// The OAuth token is read from the login keychain item that Claude Code itself maintains and is
/// only kept in memory. This never refreshes the token on its own: when it has expired, it runs
/// `claude -p /usage` so the CLI refreshes it the normal way (that command makes no model call).
actor PlanUsageService {
    private struct Credentials {
        let token: String
        let expiresAt: Date
        let planName: String?
    }

    private var lastCLIRun: Date?
    private var cliTextFallback: PlanSnapshot?

    func fetch() async -> Result<PlanSnapshot, PlanError> {
        guard var creds = await readCredentials() else { return .failure(.noCredentials) }

        if creds.expiresAt < Date().addingTimeInterval(60) {
            await refreshViaCLI()
            guard let fresh = await readCredentials() else { return .failure(.noCredentials) }
            creds = fresh
            if creds.expiresAt < Date() {
                return cliTextFallback.map { .success($0) } ?? .failure(.expired)
            }
        }

        var result = await callAPI(creds)
        if case .failure(.http(401)) = result {
            await refreshViaCLI(force: true)
            if let fresh = await readCredentials() {
                creds = fresh
                result = await callAPI(creds)
            }
            if case .failure = result, let text = cliTextFallback { return .success(text) }
        }
        return result
    }

    // MARK: Keychain

    private func readCredentials() async -> Credentials? {
        let out = await Shell.run("/usr/bin/security",
                                  ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                                  timeout: 10)
        guard let out, out.status == 0,
              let data = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return Credentials(token: token,
                           expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
                           planName: Self.planName(subscription: oauth["subscriptionType"] as? String,
                                                   tier: oauth["rateLimitTier"] as? String))
    }

    private static func planName(subscription: String?, tier: String?) -> String? {
        guard let sub = subscription else { return nil }
        let base = sub.prefix(1).uppercased() + sub.dropFirst()
        if let tier, let m = tier.range(of: #"\d+x"#, options: .regularExpression) {
            return "\(base) \(tier[m])"
        }
        return base
    }

    // MARK: CLI refresh

    private func refreshViaCLI(force: Bool = false) async {
        if let last = lastCLIRun, Date().timeIntervalSince(last) < (force ? 60 : 180) { return }
        lastCLIRun = Date()
        guard let claude = await Shell.findClaude() else { return }

        let workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = [
            "HOME": home,
            "USER": NSUserName(),
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
        ]
        let out = await Shell.run(claude, ["-p", "/usage", "--no-session-persistence", "--strict-mcp-config"],
                                  env: env, cwd: workDir, timeout: 90)
        if let out, out.status == 0 {
            cliTextFallback = Self.parseCLIText(out.stdout)
        }
    }

    /// Fallback parser for `claude -p /usage` text, e.g. "Current session: 9% used · resets ...".
    static func parseCLIText(_ text: String) -> PlanSnapshot? {
        var limits: [LimitItem] = []
        let regex = try! NSRegularExpression(pattern: #"^Current (session|week)(?: \(([^)]+)\))?: (\d+(?:\.\d+)?)% used"#,
                                             options: .anchorsMatchLines)
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let which = ns.substring(with: m.range(at: 1))
            let scope = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
            let pct = Double(ns.substring(with: m.range(at: 3))) ?? 0
            if which == "session" {
                limits.append(LimitItem(kind: "session", title: "5-hour session", percent: pct, resetsAt: nil, windowLength: 5 * 3600))
            } else if scope == nil || scope == "all models" {
                limits.append(LimitItem(kind: "weekly_all", title: "All models", percent: pct, resetsAt: nil, windowLength: 7 * 86400))
            } else {
                limits.append(LimitItem(kind: "weekly_scoped", title: scope!, percent: pct, resetsAt: nil, windowLength: 7 * 86400))
            }
        }
        return limits.isEmpty ? nil : PlanSnapshot(limits: limits, breakdown: [], planName: nil, source: .cliText)
    }

    // MARK: API

    private func callAPI(_ creds: Credentials) async -> Result<PlanSnapshot, PlanError> {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-usage-menubar/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 {
                let retry = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                return .failure(.rateLimited(retryAfter: retry))
            }
            guard code == 200 else { return .failure(.http(code)) }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var snap = Self.parse(obj) else { return .failure(.parse) }
            snap.planName = creds.planName
            Self.saveCache(obj, planName: creds.planName)
            return .success(snap)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: Cache (so a restart shows the last numbers immediately instead of querying again)

    private static let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeUsage/last-usage.json")

    private static func saveCache(_ response: [String: Any], planName: String?) {
        var root: [String: Any] = ["fetched_at": Date().timeIntervalSince1970, "response": response]
        if let planName { root["plan_name"] = planName }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: root) { try? data.write(to: cacheURL, options: .atomic) }
    }

    /// The last successful response and when it was fetched.
    static func loadCache() -> (PlanSnapshot, Date)? {
        guard let data = try? Data(contentsOf: cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let fetched = (root["fetched_at"] as? NSNumber)?.doubleValue,
              var snap = parse(response) else { return nil }
        snap.planName = root["plan_name"] as? String
        return (snap, Date(timeIntervalSince1970: fetched))
    }

    static func parse(_ obj: [String: Any]) -> PlanSnapshot? {
        var limits: [LimitItem] = []

        for d in obj["limits"] as? [[String: Any]] ?? [] {
            let kind = d["kind"] as? String ?? "unknown"
            let group = d["group"] as? String
            let pct = (d["percent"] as? NSNumber)?.doubleValue ?? 0
            let resets = parseDate(d["resets_at"] as? String)
            let window: TimeInterval? = kind == "session" || group == "session" ? 5 * 3600
                : group == "weekly" || kind.hasPrefix("weekly") ? 7 * 86400 : nil
            let title: String
            switch kind {
            case "session": title = "5-hour session"
            case "weekly_all": title = "All models"
            default:
                let scope = d["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                let name = model ?? surface ?? kind
                title = name
            }
            limits.append(LimitItem(kind: kind, title: title, percent: pct, resetsAt: resets, windowLength: window))
        }

        // Older response shape without the "limits" array.
        if limits.isEmpty {
            let legacy: [(String, String, String, TimeInterval)] = [
                ("five_hour", "session", "5-hour session", 5 * 3600),
                ("seven_day", "weekly_all", "All models", 7 * 86400),
                ("seven_day_opus", "weekly_opus", "Opus", 7 * 86400),
                ("seven_day_sonnet", "weekly_sonnet", "Sonnet", 7 * 86400),
            ]
            for (key, kind, title, window) in legacy {
                guard let d = obj[key] as? [String: Any], let u = (d["utilization"] as? NSNumber)?.doubleValue else { continue }
                limits.append(LimitItem(kind: kind, title: title, percent: u,
                                        resetsAt: parseDate(d["resets_at"] as? String), windowLength: window))
            }
        }
        guard !limits.isEmpty else { return nil }

        let names = ["claude_code": "Claude Code", "chat": "Chat", "cowork": "Cowork", "other": "Other"]
        let rows = ((obj["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []).compactMap { r -> BreakdownRow? in
            guard let key = r["key"] as? String, let pct = (r["percent"] as? NSNumber)?.doubleValue else { return nil }
            return BreakdownRow(key: key, name: names[key] ?? (r["display_name"] as? String ?? key), percent: pct)
        }
        return PlanSnapshot(limits: limits, breakdown: rows, planName: nil, source: .api)
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Python-style 6-digit fractions are not always accepted; trim to milliseconds.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let frac = s[r].prefix(4)
            if let d = f.date(from: s.replacingCharacters(in: r, with: frac)) { return d }
        }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Process helper

enum Shell {
    struct Output: Sendable { let status: Int32; let stdout: String }

    static func run(_ path: String, _ args: [String], env: [String: String]? = nil,
                    cwd: URL? = nil, timeout: TimeInterval) async -> Output? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                if let env { p.environment = env }
                if let cwd { p.currentDirectoryURL = cwd }
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: Output(status: p.terminationStatus, stdout: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    static func findClaude() async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let out = await run("/bin/zsh", ["-lc", "command -v claude"], timeout: 10)
        let path = out?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }
}
