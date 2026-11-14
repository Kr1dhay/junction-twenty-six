import SwiftUI
import Observation
import EdgeCareCore
#if os(iOS)
import UIKit
#endif
#if canImport(Network)
@preconcurrency import Network
#endif

@MainActor @Observable public final class AppSession {
    public private(set) var session: NativeSession?
    public private(set) var records: [ReferralRecord] = []
    public private(set) var wallet: [WalletEntry] = []
    public var message: String?
    public var busy = false
    public var language = "en"
    public let connected: Bool
    public var simulateOffline = false { didSet { updateConnectivity() } }
    private var pathSatisfied = true
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #endif
    private let doctor: Bool
    private let environment: [String: String]
    public init(doctor: Bool = false) {
        self.doctor = doctor
        let launchEnvironment = BundledConnection.resolve(environment: ProcessInfo.processInfo.environment,
                                                          info: Bundle.main.infoDictionary)
        if doctor {
            let saved = try? KeychainStore(service: DoctorConnectionSettings.keychainService)
                .read(account: DoctorConnectionSettings.keychainAccount)
            environment = DoctorConnectionSettings.resolve(environment: launchEnvironment, saved: saved)
        } else { environment = launchEnvironment }
        let mode = environment["EDGECARE_MODE"] ?? "local"
        connected = mode == "connected" || mode == "connected-demo"
    }
    public func start() async {
        guard session == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("EdgeCare", isDirectory: true)
            if connected {
                guard let url = URL(string: environment["EDGECARE_BASE_URL"] ?? "http://127.0.0.1:3000"), ["http", "https"].contains(url.scheme ?? "") else { throw CoreError.invalidConfiguration }
                session = try NativeSession.connectedDemo(storageDirectory: directory, baseURL: url, bearerToken: environment["EDGECARE_CLINICIAN_TOKEN"] ?? environment["EDGECARE_API_TOKEN"], issuerToken: environment["EDGECARE_ISSUER_TOKEN"])
            } else { session = try await NativeSession.local(storageDirectory: directory, seedDemo: doctor) }
            startConnectivityObserver()
            await refresh()
            // Provision only the doctor role, only for HTTPS origins, and never
            // save an issuer credential. An explicit local launch still wins.
            if doctor, connected, message == nil, let settings = DoctorConnectionSettings(environment: environment) {
                do {
                    try KeychainStore(service: DoctorConnectionSettings.keychainService)
                        .save(JSONEncoder().encode(settings), account: DoctorConnectionSettings.keychainAccount)
                } catch {
                    message = "Connected, but the connection settings could not be saved. Launch from Xcode to reconnect next time."
                }
            }
        } catch { message = Copy.text("error", language) + " (\(error))" }
    }
    public func refresh() async {
        guard let session else { return }
        if doctor {
            do { records = try await session.referrals() }
            catch { message = "Cannot reach the shared demo. Showing previously cached referrals. A new referral needs connectivity before it can be cached. (\(error))" }
        } else {
            do { _ = try await session.refreshWallet() }
            catch { message = Copy.text("cachedStatus", language) }
        }
        wallet = await session.walletEntries()
    }
    /// Present newly retrieved referrals without repeating the network list request.
    public func refreshCachedRecords() async {
        guard let session else { return }
        if doctor { records = await session.wallet.records() }
        wallet = await session.walletEntries()
    }
    private func startConnectivityObserver() {
        guard connected else { return }
        #if canImport(Network)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pathSatisfied = online; self.updateConnectivity()
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.edgecare.connectivity"))
        self.monitor = monitor
        #endif
    }
    private func updateConnectivity() {
        guard connected, let session else { return }
        let online = pathSatisfied && !simulateOffline
        Task { await session.setOnline(online); await refresh() }
    }
    public func sync() async {
        guard let session, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await session.sync()
            message = connected ? "\(Copy.text("syncDone", language)) \(result.uploaded) / \(result.confirmedSpends) / \(result.conflicts.count)" : Copy.text("local", language)
            await refresh()
        } catch { message = Copy.text("pending", language) }
    }
}

public struct SessionBanner: View {
    let connected: Bool
    let language: String
    public init(connected: Bool, language: String = "en") { self.connected = connected; self.language = language }
    public var body: some View {
        Label(Copy.text(connected ? "connected" : "local", language), systemImage: connected ? "network" : "internaldrive")
            .font(.caption).foregroundStyle(.secondary).accessibilityElement(children: .combine)
    }
}

public struct PatientRootView: View {
    @State private var app = AppSession()
    @State private var intake = IntakeViewModel(source: .patientApp)
    @State private var walletGeneration = 0
    public init() {}
    public var body: some View {
        TabView {
            NavigationStack { IntakeView(title: "Edge-Care", model: intake, app: app) }
                .tabItem { Label(Copy.text("new", intake.language), systemImage: "bubble.left.and.text.bubble.right") }
            NavigationStack { WalletView(app: app, language: intake.language) }
                .id(walletGeneration)
                .tabItem { Label(Copy.text("wallet", intake.language), systemImage: "wallet.pass") }
            NavigationStack {
                PatientProfileView(app: app, language: intake.language) { id in
                    walletGeneration += 1
                    if intake.record?.id == id || intake.editingReferral?.original.id == id { intake.reset() }
                }
            }.tabItem { Label(Copy.text("myProfile", intake.language), systemImage: "person.crop.circle") }
        }.tint(EdgeCareStyle.accent).task { await app.start() }
    }
}

public struct KioskRootView: View {
    @State private var app = AppSession()
    @State private var intake = IntakeViewModel(source: .kiosk)
    public init() {}
    public var body: some View {
        NavigationStack { IntakeView(title: "Edge-Care", model: intake, app: app, kiosk: true) }
            .tint(EdgeCareStyle.accent).task { await app.start() }
            #if os(iOS)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            #endif
    }
}
