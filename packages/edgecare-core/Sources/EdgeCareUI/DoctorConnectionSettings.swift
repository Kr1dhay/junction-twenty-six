import Foundation

/// Device authorization only, never patient codes/signatures or provider keys.
/// The doctor app stores this in a device-only Keychain item after provisioning
/// through its private Xcode Run environment.
struct DoctorConnectionSettings: Codable, Equatable {
    static let keychainService = "org.edgecare.doctor-connection"
    static let keychainAccount = "hosted-backend-v1"
    let baseURL: String
    let clinicianToken: String

    init?(environment: [String: String]) {
        guard ["connected", "connected-demo"].contains(environment["EDGECARE_MODE"] ?? ""),
              let origin = environment["EDGECARE_BASE_URL"],
              let url = URL(string: origin), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["", "/"].contains(url.path),
              let token = environment["EDGECARE_CLINICIAN_TOKEN"] ?? environment["EDGECARE_API_TOKEN"],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        baseURL = origin
        clinicianToken = token
    }

    var environment: [String: String] {
        ["EDGECARE_MODE": "connected", "EDGECARE_BASE_URL": baseURL, "EDGECARE_CLINICIAN_TOKEN": clinicianToken]
    }

    static func resolve(environment: [String: String], saved: Data?) -> [String: String] {
        // Explicit launch configuration wins in its entirety. Never attach a
        // saved credential to a new host or override an explicit offline run.
        let keys = ["EDGECARE_MODE", "EDGECARE_BASE_URL", "EDGECARE_CLINICIAN_TOKEN",
                    "EDGECARE_API_TOKEN", "EDGECARE_ISSUER_TOKEN"]
        guard !keys.contains(where: { environment[$0] != nil }),
              let saved, let settings = try? JSONDecoder().decode(Self.self, from: saved),
              Self(environment: settings.environment) != nil else { return environment }
        return environment.merging(settings.environment) { current, _ in current }
    }
}
