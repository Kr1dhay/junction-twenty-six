import CryptoKit
import Foundation

/// One app's lifecycle. Local mode uses only local actors; connected-demo uses the synthetic HTTP registry.
public actor NativeSession {
    public nonisolated let wallet: ReferralWallet
    public nonisolated let outbox: ReferralOutbox
    public nonisolated let chain: any ChainClient
    public nonisolated let api: any ReferralAPI
    public nonisolated let configuration: AppConfiguration
    private let appointmentAPI: (any AppointmentAPI)?
    private let voiceClient: ConsentGatedVoiceClient?
    public nonisolated let consultationAPI: any ConsultationAPI
    public nonisolated let consultationOutbox: ConsultationOutbox?
    private var online: Bool
    private var verifying: Set<String> = []

    public init(configuration: AppConfiguration, wallet: ReferralWallet, outbox: ReferralOutbox,
                chain: any ChainClient, api: any ReferralAPI, online: Bool = true, voiceClient: ConsentGatedVoiceClient? = nil,
                consultationAPI: any ConsultationAPI = MockConsultationAPI(), consultationOutbox: ConsultationOutbox? = nil,
                appointmentAPI: (any AppointmentAPI)? = nil) {
        self.configuration = configuration; self.wallet = wallet; self.outbox = outbox
        self.chain = chain; self.api = api; self.online = online; self.voiceClient = voiceClient
        self.consultationAPI = consultationAPI; self.consultationOutbox = consultationOutbox; self.appointmentAPI = appointmentAPI
    }
    private static func storageKey(directory: URL) throws -> Data {
        let account = storageAccount(directory: directory, home: URL(fileURLWithPath: NSHomeDirectory()),
                                     bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.edgecare")
        let keychain = KeychainStore()
        if let existing = try keychain.read(account: account) {
            guard existing.count == 32 else { throw CoreError.invalidConfiguration }
            return existing
        }
        let names = ["local-wallet.enc", "local-outbox.enc", "connected-wallet.enc", "connected-outbox.enc", "connected-consultations.enc"]
        let files = try names.compactMap { name -> Data? in
            let url = directory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        }
        // Main and the voice branch introduced different stable v2 account names.
        // Preserve either install's data, but only migrate a key that authenticates
        // all existing encrypted stores, including the consultation outbox.
        if let previous = try keychain.read(account: storageAccount(directory: directory)), previous.count == 32,
           files.isEmpty || KeychainStore.matchingWalletKey(encryptedFiles: files, candidates: [previous]) != nil {
            try keychain.save(previous, account: account)
            return previous
        }
        return try keychain.walletKey(account: account, authenticating: files)
    }
    /// Compatibility with main's home-relative account naming.
    static func storageAccount(directory: URL, home: String = NSHomeDirectory()) -> String {
        var path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        if path == root || path.hasPrefix(root + "/") { path = "~" + path.dropFirst(root.count) }
        return "wallet-v2-" + digest(path)
    }
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func storageAccount(directory: URL, home: URL, bundleIdentifier: String) -> String {
        let path = directory.standardizedFileURL.path, root = home.standardizedFileURL.path
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count)) : path
        let identity = bundleIdentifier + ":" + relative
        return "wallet-v2-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func local(storageDirectory: URL, seedDemo: Bool = false) async throws -> NativeSession {
        let key = try storageKey(directory: storageDirectory)
        let wallet = try ReferralWallet(storeURL: storageDirectory.appendingPathComponent("local-wallet.enc"), key: key)
        let outbox = try ReferralOutbox(storeURL: storageDirectory.appendingPathComponent("local-outbox.enc"), key: key)
        let chain = try MockChainClient(storeURL: storageDirectory.appendingPathComponent("local-registry.json"))
        let api = MockReferralAPI(records: await wallet.records())
        let session = NativeSession(configuration: .demo, wallet: wallet, outbox: outbox, chain: chain, api: api, online: false)
        if seedDemo {
            for record in try DemoData.referrals() {
                try await chain.create(referralID: record.id, hash: record.commitmentHash)
                if record.status == .spent, let account = await chain.read(referralID: record.id), !account.spent {
                    try await chain.spend(referralID: record.id)
                }
                try await api.submit(record)
                let account = await chain.read(referralID: record.id)
                try await wallet.store(record, state: account?.spent == true ? .spent : .available, account: account)
            }
        }
        // Finish any operation interrupted between durable enqueue and local persistence.
        _ = try await session.sync()
        return session
    }
    public static func connectedDemo(storageDirectory: URL, baseURL: URL, bearerToken: String? = nil, issuerToken: String? = nil) throws -> NativeSession {
        let key = try storageKey(directory: storageDirectory)
        let wallet = try ReferralWallet(storeURL: storageDirectory.appendingPathComponent("connected-wallet.enc"), key: key)
        let outbox = try ReferralOutbox(storeURL: storageDirectory.appendingPathComponent("connected-outbox.enc"), key: key)
        let chain = HTTPDemoChainClient(baseURL: baseURL, configuration: .connectedDemo, bearerToken: bearerToken, issuerToken: issuerToken)
        let api = RESTReferralAPI(baseURL: baseURL, configuration: .connectedDemo, bearerToken: bearerToken, issuerToken: issuerToken)
        let voice = ConsentGatedVoiceClient(baseURL: baseURL, configuration: .connectedDemo, bearerToken: issuerToken ?? bearerToken)
        let consultations = RESTConsultationAPI(baseURL: baseURL, configuration: .connectedDemo, bearerToken: bearerToken)
        let consultationOutbox = try ConsultationOutbox(storeURL: storageDirectory.appendingPathComponent("connected-consultations.enc"), key: key)
        let appointments = RESTAppointmentAPI(baseURL: baseURL, configuration: .connectedDemo, bearerToken: bearerToken, issuerToken: issuerToken)
        return NativeSession(configuration: .connectedDemo, wallet: wallet, outbox: outbox, chain: chain, api: api, voiceClient: voice,
                             consultationAPI: consultations, consultationOutbox: consultationOutbox, appointmentAPI: appointments)
    }
    /// The edit session was unlocked with the patient's code and signature on this device.
    public func appointmentVerification(for authorization: ReferralEditSession) -> PatientVerification {
        PatientVerification(referralID: authorization.original.id, commitmentHash: authorization.original.commitmentHash)
    }
    private func appointments(record: ReferralRecord, verification: PatientVerification) throws -> any AppointmentAPI {
        guard configuration.allowsNetwork, online else { throw CoreError.offline }
        guard verification.referralID == record.id, verification.commitmentHash == record.commitmentHash,
              Date().timeIntervalSince(verification.verifiedAt) < 15 * 60,
              (AppointmentSlot.date(record.expiresAt).map { $0 > Date() } ?? false) else { throw CoreError.verificationFailed }
        guard let appointmentAPI else { throw CoreError.notConfigured }
        return appointmentAPI
    }
    public func appointmentAvailability(record: ReferralRecord, verification: PatientVerification) async throws -> AppointmentAvailability {
        let service = try appointments(record: record, verification: verification)
        let booking = try await service.appointment(referralID: record.id)
        let slots = try await service.slots()
        let expiry = AppointmentSlot.date(record.expiresAt) ?? .distantPast
        return AppointmentAvailability(slots: slots.filter { $0.demo && ($0.endDate.map { $0 <= expiry } ?? false) }, appointment: booking)
    }
    public func bookAppointment(record: ReferralRecord, verification: PatientVerification, slotID: String, operationID: String) async throws -> AppointmentBooking {
        let service = try appointments(record: record, verification: verification)
        return try await service.book(referralID: record.id, slotID: slotID, operationID: operationID)
    }
    public func cancelAppointment(record: ReferralRecord, verification: PatientVerification, appointmentID: String) async throws {
        let service = try appointments(record: record, verification: verification)
        try await service.cancel(referralID: record.id, appointmentID: appointmentID)
    }
    /// Patient ownership login includes expired referrals; expiry must not prevent erasure.
    /// Merge only this device's cache so unsent records can also be removed.
    public func patientProfiles(passcode: String, strokes: [[SignaturePoint]]) async throws -> [PatientProfileAccess] {
        try enforceLocalAdapters()
        try CommitmentCrypto.validate(passcode: passcode)
        _ = try SignatureMatcher.extract(strokes)
        guard configuration.demoMode || online else { throw CoreError.offline }
        var records = Dictionary((await wallet.records()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for record in try await api.list() { records[record.id] = record }
        try Task.checkCancellation()
        return records.values.sorted { $0.createdAt > $1.createdAt }.compactMap {
            try? PatientProfileAccess(record: $0, passcode: passcode, strokes: strokes)
        }
    }
    public func deletePatientProfile(_ access: PatientProfileAccess) async throws {
        try enforceLocalAdapters()
        guard configuration.demoMode || online else { throw CoreError.offline }
        guard Date().timeIntervalSince(access.verifiedAt) >= 0,
              Date().timeIntervalSince(access.verifiedAt) < 300 else { throw CoreError.verificationFailed }
        // Persist the patient's deletion intent first. Interrupted deletion never reuploads
        // an old referral on restart; the patient can sign in again and retry safely.
        try await wallet.beginDeletion(id: access.id)
        try await outbox.discard(referralID: access.id)
        try await consultationOutbox?.discard(referralID: access.id)
        try await api.deleteProfile(access)
        if let local = chain as? MockChainClient { try await local.removeProfile(referralID: access.id) }
        try await wallet.remove(id: access.id)
    }
    public func isOnline() -> Bool { online }
    public func voiceTurn(audio: Data? = nil, mimeType: String = "audio/mp4", text: String? = nil,
                          language: String? = nil, profile: ClinicalProfile = ClinicalProfile(),
                          history: [VoiceConversationTurn] = [], consent: Bool) async throws -> VoiceTurnResponse {
        guard configuration.allowsNetwork, online else { throw CoreError.offline }
        guard consent else { throw CoreError.consentRequired }
        guard let voiceClient else { throw CoreError.providerUnavailable }
        return try await voiceClient.turn(VoiceTurnRequest(consent: consent, audio: audio, mimeType: mimeType,
            text: text, language: language, profile: profile, history: history))
    }
    public func normalizeProfile(text: String, language: String? = nil, profile: ClinicalProfile = ClinicalProfile(),
                                 history: [VoiceConversationTurn] = [], consent: Bool) async throws -> VoiceTurnResponse {
        guard configuration.allowsNetwork, online else { throw CoreError.offline }
        guard consent else { throw CoreError.consentRequired }
        guard let voiceClient else { throw CoreError.providerUnavailable }
        return try await voiceClient.normalize(VoiceTurnRequest(consent: consent, text: text, language: language, profile: profile, history: history))
    }
    public func voiceEngine() async throws -> VoiceEngine {
        guard configuration.allowsNetwork, online else { throw CoreError.offline }
        guard let voiceClient else { throw CoreError.providerUnavailable }
        return try await voiceClient.engine()
    }
    public func liveVoiceSession(language: String?, profile: ClinicalProfile, history: [VoiceConversationTurn], consent: Bool) async throws -> GeminiLiveCredentials {
        guard configuration.allowsNetwork, online else { throw CoreError.offline }
        guard consent else { throw CoreError.consentRequired }
        guard let voiceClient else { throw CoreError.providerUnavailable }
        return try await voiceClient.liveSession(consent: consent, language: language, profile: profile, history: history)
    }
    /// Called by the app's connectivity observer and airplane-mode demo control.
    public func setOnline(_ value: Bool) async {
        online = value
        if value { _ = try? await sync() }
    }
    public func walletEntries() async -> [WalletEntry] {
        // Recover a crash after enqueueSpend but before updating its wallet presentation.
        for operation in await outbox.pendingSpends() {
            if let entry = await wallet.entry(id: operation.referralID), entry.state == .available {
                try? await wallet.update(id: operation.referralID, state: .provisionalSpend)
            }
        }
        return await wallet.allEntries()
    }
    /// Reads only commitment accounts for referrals already held in this encrypted wallet.
    /// A provisional spend must reconcile its stable operation ID before it can be called confirmed.
    public func refreshWallet() async throws -> [WalletEntry] {
        try enforceLocalAdapters()
        guard configuration.demoMode || (configuration.allowsNetwork && online) else { return await walletEntries() }
        let entries = await walletEntries()
        for entry in entries {
            guard configuration.demoMode || online else { break }
            if await wallet.deletionRequested(id: entry.id) {
                do { _ = try await api.fetchVerificationEnvelope(id: entry.id) }
                catch CoreError.notFound {
                    try await outbox.discard(referralID: entry.id)
                    try await consultationOutbox?.discard(referralID: entry.id)
                    if let local = chain as? MockChainClient { try await local.removeProfile(referralID: entry.id) }
                    try await wallet.remove(id: entry.id)
                }
                continue
            }
            guard entry.state == .available else { continue }
            guard !verifying.contains(entry.id) else { continue }
            if let account = try await chain.read(referralID: entry.id) {
                guard !verifying.contains(entry.id) else { continue }
                // Wallet performs a second state check atomically after the asynchronous chain read.
                try await wallet.reconcile(account: account, id: entry.id)
            }
        }
        return await walletEntries()
    }
    public func enroll(draft: EnrollmentDraft, strokes: [[SignaturePoint]], passcode: String, confirmation: String) async throws -> ReferralRecord {
        let record = try EnrollmentService().enroll(draft: draft, strokes: strokes, passcode: passcode, confirmation: confirmation)
        // Save the encrypted wallet first. No PIN is retained in either durable store.
        try await wallet.store(record, state: .pendingEnrollment)
        try await outbox.enqueue(record)
        // A transport failure leaves a complete, durable enrollment in this device's wallet.
        _ = try? await sync()
        return record
    }
    public func updateReferral(_ update: ReferralUpdate, authorization: ReferralEditSession) async throws -> ReferralRecord {
        try enforceLocalAdapters()
        guard configuration.demoMode || online else { throw CoreError.offline }
        guard update.preservesIdentity, update.expected == authorization.original else { throw CoreError.conflict }
        let pending = await outbox.pending()
        guard !pending.contains(where: { $0.id == update.record.id }) else { throw CoreError.conflict }
        try await api.update(update)
        let account = try? await chain.read(referralID: update.record.id)
        try await wallet.store(update.record, state: account?.spent == true || update.record.status == .spent ? .spent : .available, account: account)
        return update.record
    }
    public func referrals() async throws -> [ReferralRecord] {
        try enforceLocalAdapters()
        guard configuration.demoMode || online else { return await wallet.records() }
        do {
            let records = try await api.list()
            for record in records {
                let account = try await chain.read(referralID: record.id)
                try await wallet.store(record, state: account?.spent == true || record.status == .spent ? .spent : .available, account: account)
            }
            return await wallet.records()
        } catch {
            let cached = await wallet.records()
            if !cached.isEmpty, Self.isTransportFailure(error) { return cached }
            throw error
        }
    }
    public func cacheReferral(id: String) async throws -> ReferralRecord {
        try enforceLocalAdapters()
        guard let uuid = UUID(uuidString: id) else { throw CoreError.notFound }
        let canonicalID = uuid.uuidString.lowercased()
        if !configuration.demoMode && !online {
            guard let entry = await wallet.entry(id: canonicalID) else { throw CoreError.offline }
            return entry.record
        }
        do {
            let record = try await api.fetchVerificationEnvelope(id: canonicalID)
            let account = try await chain.read(referralID: canonicalID)
            try await wallet.store(record, state: account?.spent == true || record.status == .spent ? .spent : .available, account: account)
            return record
        } catch {
            if Self.isTransportFailure(error), let cached = await wallet.entry(id: canonicalID) { return cached.record }
            throw error
        }
    }
    /// Retrieves clinician-authorized envelopes and matches their encrypted templates
    /// on this device. Neither the code nor fresh signature is sent to the API.
    /// Return every match: a person may have multiple referrals, and demo signatures
    /// are not unique enough to justify silently picking one.
    #if DEBUG
    /// TESTING ONLY (Debug builds): this code verifies a patient without a signature.
    /// Compiled out of Release, so it never ships in TestFlight/App Store builds.
    public static let testingBypassPasscode = "1987"
    #endif
    public func findReferrals(passcode: String, strokes: [[SignaturePoint]], now: Date = Date()) async throws -> ReferralSearchResult {
        try enforceLocalAdapters()
        try CommitmentCrypto.validate(passcode: passcode)
        _ = try SignatureMatcher.extract(strokes)
        try Task.checkCancellation()
        let records: [ReferralRecord]
        var localOnly = configuration.demoMode || !online
        if !configuration.demoMode && !online {
            records = await wallet.records()
        } else {
            do { records = try await api.list() }
            catch {
                guard Self.isTransportFailure(error) else { throw error }
                records = await wallet.records(); localOnly = true
            }
        }
        try Task.checkCancellation()
        var matches: [VerifiedReferralMatch] = []
        for record in records.sorted(by: { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }) {
            try Task.checkCancellation()
            // A wrong code, different signature, expired or corrupt envelope is not a match.
            guard let hash = try? VerificationService.authenticate(record: record, passcode: passcode, strokes: strokes, now: now) else { continue }
            try await wallet.store(record, state: record.status == .spent ? .spent : .available)
            matches.append(VerifiedReferralMatch(record: record, verification: PatientVerification(referralID: record.id, commitmentHash: hash, verifiedAt: now)))
        }
        try Task.checkCancellation()
        return ReferralSearchResult(matches: matches, searchedLocalOnly: localOnly)
    }
    /// Authenticates the patient for this visit without consuming the referral. It succeeds
    /// even after the referral was marked used, so the clinician can log a new visit.
    public func verify(record: ReferralRecord, passcode: String, strokes: [[SignaturePoint]]) async throws -> PatientVerification {
        try enforceLocalAdapters()
        #if DEBUG
        // TESTING ONLY: the bypass code skips the signature and reuses the record's own
        // commitment hash as a stand-in proof, so `markUsed` still accepts it.
        if passcode == Self.testingBypassPasscode {
            return PatientVerification(referralID: record.id, commitmentHash: record.commitmentHash)
        }
        #endif
        let hash = try VerificationService.authenticate(record: record, passcode: passcode, strokes: strokes)
        return PatientVerification(referralID: record.id, commitmentHash: hash)
    }
    /// Consumes the referral's single use after a successful `verify`. Verification and
    /// consumption are separate actions: verifying the patient never spends the referral.
    public func markUsed(record: ReferralRecord, verification: PatientVerification) async throws -> VerificationOutcome {
        try enforceLocalAdapters()
        guard verification.referralID == record.id, verification.commitmentHash == record.commitmentHash else { throw CoreError.verificationFailed }
        // Prevent actor reentrancy from allowing two local attempts to queue independently.
        guard !verifying.contains(record.id) else { throw CoreError.alreadySpent }
        verifying.insert(record.id); defer { verifying.remove(record.id) }
        let hash = verification.commitmentHash
        if let existing = await wallet.entry(id: record.id) {
            guard ![.spent, .provisionalSpend, .conflict].contains(existing.state) else { throw CoreError.alreadySpent }
        }
        if configuration.demoMode {
            guard let account = try await chain.read(referralID: record.id), account.commitmentHash == hash else { throw CoreError.verificationFailed }
            guard !account.spent else { throw CoreError.alreadySpent }
            try await chain.spend(referralID: record.id, hash: hash, operationID: UUID().uuidString.lowercased())
            try await wallet.store(record, state: .spent, account: try await chain.read(referralID: record.id))
            return VerificationOutcome(settlement: .localDemo, message: "Verified and spent in this device's local demo registry. Other devices do not share this registry.")
        }
        if online {
            do {
                guard let account = try await chain.read(referralID: record.id), account.commitmentHash == hash else { throw CoreError.verificationFailed }
                guard !account.spent else { throw CoreError.alreadySpent }
                try await wallet.store(record, account: account)
            } catch {
                guard Self.isTransportFailure(error) else { throw error }
            }
        }
        guard let cached = await wallet.entry(id: record.id), let account = cached.cachedAccount,
              account.commitmentHash == hash else { throw CoreError.noCachedCommitment }
        guard !account.spent else { throw CoreError.alreadySpent }
        let operation = PendingSpend(referralID: record.id, commitmentHash: hash)
        // Enqueue first: after a crash, the stable operation can still reconcile to its original winner.
        try await outbox.enqueueSpend(operation)
        try await wallet.update(id: record.id, state: .provisionalSpend)
        if online { _ = try? await sync() }
        guard let result = await wallet.entry(id: record.id) else { throw CoreError.notFound }
        switch result.state {
        case .spent: return VerificationOutcome(settlement: .confirmed, message: "Verified. The shared demo registry accepted this referral's single use.")
        case .conflict: throw CoreError.conflict
        default: return VerificationOutcome(settlement: .provisional, message: "Signature and code matched the cached commitment. This use is provisional until the shared registry confirms it. The first accepted spend wins.")
        }
    }
    // MARK: Consultations (connected mode only; local mode never contacts a provider)

    public var canConsult: Bool { configuration.allowsNetwork && online && !(consultationAPI is MockConsultationAPI) }
    private func requireConsultation() throws {
        guard configuration.allowsNetwork, !(consultationAPI is MockConsultationAPI) else { throw CoreError.providerUnavailable }
        guard online else { throw CoreError.offline }
    }
    public func startConsultation(_ request: ConsultationSessionRequest) async throws -> ConsultationSessionCredentials {
        try requireConsultation(); return try await consultationAPI.startSession(request)
    }
    public func translateConsultation(_ request: ConsultationTranslateRequest) async throws -> ConsultationTranslation {
        try requireConsultation(); return try await consultationAPI.translate(request)
    }
    public func draftConsultationNotes(_ request: ConsultationNotesRequest) async throws -> ConsultationNotesDraft {
        try requireConsultation(); return try await consultationAPI.draftNotes(request)
    }
    public func speakConsultation(_ request: ConsultationSpeakRequest) async throws -> ConsultationSpeech {
        try requireConsultation(); return try await consultationAPI.speak(request)
    }
    public enum ConsultationSubmission: Sendable, Equatable { case saved, queued }
    /// Durable first: the confirmed record is queued before upload, so losing the connection
    /// after both confirmations never loses the agreed consultation.
    public func submitConsultation(_ record: ConsultationRecord) async throws -> ConsultationSubmission {
        guard let consultationOutbox, configuration.allowsNetwork else { throw CoreError.providerUnavailable }
        guard !(await wallet.deletionRequested(id: record.referralID)) else { throw CoreError.notFound }
        try await consultationOutbox.enqueue(record)
        guard online else { return .queued }
        do {
            try await consultationAPI.submit(record)
            try await consultationOutbox.remove(id: record.id)
            return .saved
        } catch {
            if Self.isTransportFailure(error) { return .queued }
            throw error
        }
    }
    public func pendingConsultations() async -> [ConsultationRecord] { await consultationOutbox?.pending() ?? [] }
    private func flushConsultations() async -> (uploaded: Int, conflicts: [String]) {
        guard let consultationOutbox, configuration.allowsNetwork, online else { return (0, []) }
        var uploaded = 0; var conflicts: [String] = []
        for record in await consultationOutbox.pending() {
            do { try await consultationAPI.submit(record); try await consultationOutbox.remove(id: record.id); uploaded += 1 }
            catch {
                if Self.isTransportFailure(error) { break }
                // A rejected record stays queued for clinician attention rather than being silently dropped.
                conflicts.append("consultation:\(record.id)")
            }
        }
        return (uploaded, conflicts)
    }

    public func sync() async throws -> SyncReport {
        try enforceLocalAdapters()
        // Finish a crash between persisting deletion intent and discarding queued writes.
        for entry in await wallet.allEntries() {
            if await wallet.deletionRequested(id: entry.id) {
                try await outbox.discard(referralID: entry.id)
                try await consultationOutbox?.discard(referralID: entry.id)
            }
        }
        // Recover a crash between the wallet write and enrollment-outbox write.
        let pendingRecords = await outbox.pending()
        let pendingIDs = Set(pendingRecords.map(\.id))
        for entry in await wallet.allEntries() where entry.state == .pendingEnrollment && !pendingIDs.contains(entry.id) {
            guard !(await wallet.deletionRequested(id: entry.id)) else { continue }
            try await outbox.enqueue(entry.record)
        }
        if configuration.demoMode {
            guard let chain = chain as? MockChainClient, let api = api as? MockReferralAPI else { throw CoreError.invalidConfiguration }
            let report = try await outbox.flushLocal(chain: chain, api: api, wallet: wallet)
            _ = try await refreshWallet()
            return report
        }
        guard online else { return SyncReport() }
        let report = try await outbox.flush(chain: chain, api: api, configuration: configuration, wallet: wallet)
        let consultations = await flushConsultations()
        _ = try await refreshWallet()
        return SyncReport(uploaded: report.uploaded + consultations.uploaded, confirmedSpends: report.confirmedSpends, conflicts: report.conflicts + consultations.conflicts)
    }
    private func enforceLocalAdapters() throws {
        if configuration.demoMode {
            guard chain is MockChainClient, api is MockReferralAPI else { throw CoreError.invalidConfiguration }
        }
    }
    private static func isTransportFailure(_ error: any Error) -> Bool {
        error is URLError || (error as? CoreError) == .offline
    }
}
