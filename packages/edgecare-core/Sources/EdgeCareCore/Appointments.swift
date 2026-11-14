import Foundation

public struct AppointmentSlot: Codable, Sendable, Equatable, Identifiable {
    public let slotID: String
    public let startsAt: String
    public let endsAt: String
    public let timeZone: String
    public let location: String
    public let service: String
    public let demo: Bool
    public var id: String { slotID }
    public var startDate: Date? { Self.date(startsAt) }
    public var endDate: Date? { Self.date(endsAt) }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    enum CodingKeys: String, CodingKey {
        case slotID = "slot_id", startsAt = "starts_at", endsAt = "ends_at", timeZone = "time_zone"
        case location, service, demo
    }
}
public struct AppointmentBooking: Codable, Sendable, Equatable, Identifiable {
    public let appointmentID: String
    public let referralID: String
    public let slotID: String
    public let startsAt: String
    public let endsAt: String
    public let timeZone: String
    public let location: String
    public let service: String
    public let status: String
    public let demo: Bool
    public var id: String { appointmentID }
    public var startDate: Date? { AppointmentSlot.date(startsAt) }
    enum CodingKeys: String, CodingKey {
        case appointmentID = "appointment_id", referralID = "referral_id", slotID = "slot_id"
        case startsAt = "starts_at", endsAt = "ends_at", timeZone = "time_zone"
        case location, service, status, demo
    }
}
public struct AppointmentAvailability: Sendable {
    public let slots: [AppointmentSlot]
    public let appointment: AppointmentBooking?
}
public protocol AppointmentAPI: Sendable {
    func slots() async throws -> [AppointmentSlot]
    func appointment(referralID: String) async throws -> AppointmentBooking?
    func book(referralID: String, slotID: String, operationID: String) async throws -> AppointmentBooking
    func cancel(referralID: String, appointmentID: String) async throws
}
public struct RESTAppointmentAPI: AppointmentAPI {
    private let transport: DemoHTTPTransport
    public init(baseURL: URL, configuration: AppConfiguration, bearerToken: String? = nil, issuerToken: String? = nil) {
        transport = DemoHTTPTransport(baseURL: baseURL, configuration: configuration, bearerToken: bearerToken, issuerToken: issuerToken)
    }
    private struct Slots: Decodable { let slots: [AppointmentSlot] }
    private struct Result: Decodable { let appointment: AppointmentBooking? }
    private struct BookingRequest: Encodable {
        let slot_id: String
        let operation_id: String
    }
    private struct Cancellation: Encodable { let appointment_id: String }
    public func slots() async throws -> [AppointmentSlot] {
        let data = try await transport.request(path: ["appointments", "slots"], issuer: true)
        return try JSONDecoder().decode(Slots.self, from: data).slots
    }
    public func appointment(referralID: String) async throws -> AppointmentBooking? {
        let data = try await transport.request(path: ["referrals", referralID, "appointment"], issuer: true)
        return try JSONDecoder().decode(Result.self, from: data).appointment
    }
    public func book(referralID: String, slotID: String, operationID: String) async throws -> AppointmentBooking {
        let body = try JSONEncoder().encode(BookingRequest(slot_id: slotID, operation_id: operationID))
        let data = try await transport.request(path: ["referrals", referralID, "appointment"], method: "POST", body: body, issuer: true)
        guard let booking = try JSONDecoder().decode(Result.self, from: data).appointment, booking.demo,
              booking.referralID == referralID, booking.slotID == slotID, booking.appointmentID == operationID else { throw CoreError.invalidResponse }
        return booking
    }
    public func cancel(referralID: String, appointmentID: String) async throws {
        let body = try JSONEncoder().encode(Cancellation(appointment_id: appointmentID))
        _ = try await transport.request(path: ["referrals", referralID, "appointment"], method: "DELETE", body: body, issuer: true)
    }
}
