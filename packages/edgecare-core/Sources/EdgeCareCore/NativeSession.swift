import CryptoKit
import Foundation

/// One app's lifecycle. Local mode uses only local actors; connected-demo uses the synthetic HTTP registry.
public actor NativeSession {
    public nonisolated let wallet: ReferralWallet
    public nonisolated let outbox: ReferralOutbox
    public nonisolated let chain: any ChainClient
    public nonisolated let api: any ReferralAPI
    public nonisolated let configuration: AppConfiguration
    private let voiceClient: ConsentGatedVoiceClient?
    private var online: Bool
    private var verifying: Set<String> = []

    public init(configuration: AppConfiguration, wallet: ReferralWallet, outbox: ReferralOutbox,
                chain: any ChainClient, api: any ReferralAPI, online: Bool = true, voiceClient: ConsentGatedVoiceClient? = nil) {
        self.configuration = configuration; self.wallet = wallet; self.outbox = outbox
        self.chain = chain; self.api = api; self.online = online; self.voiceClient = voiceClient
    }
    private static func storageKey(directory: URL) throws -> Data {
        let account = "wallet-v1-" + SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return try KeychainStore().walletKey(account: account)
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
        return NativeSession(configuration: .connectedDemo, wallet: wallet, outbox: outbox, chain: chain, api: api, voiceClient: voice)
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
        for entry in entries where entry.state == .available {
            guard configuration.demoMode || online else { break }
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
    /// Authenticates the patient for this visit without consuming the referral. It succeeds
    /// even after the referral was marked used, so the clinician can log a new visit.
    public func verify(record: ReferralRecord, passcode: String, strokes: [[SignaturePoint]]) async throws -> PatientVerification {
        try enforceLocalAdapters()
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
    public func sync() async throws -> SyncReport {
        try enforceLocalAdapters()
        // Recover a crash between the wallet write and enrollment-outbox write.
        let pendingRecords = await outbox.pending()
        let pendingIDs = Set(pendingRecords.map(\.id))
        for entry in await wallet.allEntries() where entry.state == .pendingEnrollment && !pendingIDs.contains(entry.id) {
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
        _ = try await refreshWallet()
        return report
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
