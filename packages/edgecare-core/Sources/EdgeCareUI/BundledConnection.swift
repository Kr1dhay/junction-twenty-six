import Foundation

/// Connection defaults compiled into a device build's Info.plist, so an app
/// opened from the home screen (with no launch environment) still reaches the
/// hosted demo. Any explicit EDGECARE_* launch value wins in its entirety, which
/// keeps simulator scripts, UI tests and explicit offline runs unchanged.
enum BundledConnection {
    static let keys = ["EDGECARE_MODE", "EDGECARE_BASE_URL", "EDGECARE_CLINICIAN_TOKEN",
                       "EDGECARE_API_TOKEN", "EDGECARE_ISSUER_TOKEN"]

    static func resolve(environment: [String: String], info: [String: Any]?) -> [String: String] {
        guard !keys.contains(where: { environment[$0] != nil }), let info else { return environment }
        var bundled: [String: String] = [:]
        for key in keys {
            // Unset build settings expand to "" in Info.plist; ignore those.
            guard let value = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !value.contains("$(") else { continue }
            bundled[key] = value
        }
        guard ["connected", "connected-demo"].contains(bundled["EDGECARE_MODE"] ?? ""),
              let origin = bundled["EDGECARE_BASE_URL"], URL(string: origin)?.scheme == "https" else { return environment }
        return environment.merging(bundled) { current, _ in current }
    }
}
