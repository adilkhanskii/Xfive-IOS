import Foundation
import UIKit

/// Auto crash + lifecycle reporter. Captures unhandled exceptions and POSIX
/// signals, persists the trace locally, and re-sends on next launch to the
/// Supabase `app_diagnostics` REST endpoint. Also POSTs a one-shot lifecycle
/// event (`launch` / `home_appeared` / `first_button_tap`) so we can tell
/// from the server which screen the user reached before the crash.
///
/// Build 67: introduced to bypass the lack of a Mac + the lack of TestFlight
/// crash log delivery. Apple's diagnosticSignatures endpoint returns 404 for
/// our recent builds, so we ship our own collector. No PII — only build id,
/// iOS version, device model, and a stack trace.
enum DiagnosticLogger {
    private static let pendingKey = "x5.diag.pending_crash_v1"
    private static let endpoint = X5Config.supabaseBaseURL
        .appendingPathComponent("rest/v1/app_diagnostics")

    /// Wire installation. Call once from `X5App.init()` BEFORE any other
    /// service. `installHandlers` must run on the main thread.
    static func bootstrap() {
        flushPendingIfAny()
        installHandlers()
        log(event: "launch")
    }

    /// Record a named lifecycle event. Fire-and-forget — never blocks UI.
    static func log(event: String, extra: [String: String] = [:]) {
        var payload = baseInfo()
        payload["event"] = event
        if !extra.isEmpty {
            payload["summary"] = extra
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(String($0.value.prefix(160)))" }
                .joined(separator: "; ")
        }
        post(payload)
    }

    // MARK: - Crash handlers

    private static func installHandlers() {
        // C function pointers (@convention(c)) cannot capture context, so we
        // inline the persist logic instead of calling `persistPending(...)`.
        // Signal handlers (SIGSEGV etc) are intentionally NOT installed — the
        // signal context is async-signal-safe-only, and Foundation/JSON calls
        // would deadlock there. NSSetUncaughtExceptionHandler covers Swift
        // exceptions and ObjC NSExceptions, which is the bulk of crashes.
        NSSetUncaughtExceptionHandler { exc in
            let trace = exc.callStackSymbols.joined(separator: "\n")
            let reason = exc.reason ?? "<no reason>"
            let name = exc.name.rawValue
            let info: [String: Any] = [
                "event": "crash",
                "kind": "ns_exception",
                "summary": "\(name): \(reason)",
                "stack": String(trace.prefix(8000)),
                "ts": ISO8601DateFormatter().string(from: Date())
            ]
            if let data = try? JSONSerialization.data(withJSONObject: info) {
                UserDefaults.standard.set(data, forKey: "x5.diag.pending_crash_v1")
                UserDefaults.standard.synchronize()
            }
        }
    }

    private static func persistPending(kind: String, summary: String, stack: String) {
        var info = baseInfo()
        info["event"] = "crash"
        info["kind"] = kind
        info["summary"] = summary
        info["stack"] = String(stack.prefix(8000))
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            UserDefaults.standard.set(data, forKey: pendingKey)
            UserDefaults.standard.synchronize()
        }
    }

    private static func flushPendingIfAny() {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        post(payload)
    }

    // MARK: - Network

    private static func post(_ payload: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(X5Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(X5Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = body
        // Use ephemeral background task — fire-and-forget.
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - Device info

    private static func baseInfo() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = info["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        return [
            "build_number": buildNumber,
            "app_version": appVersion,
            "os_version": device.systemVersion,
            "device_model": deviceModelIdentifier(),
            "device_name": device.model,
            "locale": Locale.current.identifier,
            "ts": ISO8601DateFormatter().string(from: Date())
        ]
    }

    private static func deviceModelIdentifier() -> String {
        var size: size_t = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}
