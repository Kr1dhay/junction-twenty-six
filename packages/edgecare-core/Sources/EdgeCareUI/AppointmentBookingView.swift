import SwiftUI
import EdgeCareCore

@MainActor struct AppointmentBookingView: View {
    @Bindable var model: IntakeViewModel
    @Bindable var app: AppSession
    @State private var passcode = ""
    @State private var strokes: [[SignaturePoint]] = []
    @State private var candidates: [VerifiedReferralMatch] = []
    @State private var record: ReferralRecord?
    @State private var verification: PatientVerification?
    @State private var slots: [AppointmentSlot] = []
    @State private var booking: AppointmentBooking?
    @State private var selectedDay = ""
    @State private var selected: String?
    @State private var operationID = UUID().uuidString.lowercased()
    @State private var busy = false
    @State private var loaded = false
    @State private var errorKey: String?
    @State private var cancelling = false
    @State private var generation = 0
    @State private var task: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    private func t(_ key: String) -> String { Copy.text(key, model.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(t("bookAppointment")).font(.largeTitle.weight(.semibold))
            Text(t("demoBookingNotice")).foregroundStyle(.secondary)
            if !app.connected {
                Text(t("bookingConnectionRequired"))
            } else if record == nil {
                Text(t("verifyToBook"))
                PINField(title: t("enterPin"), value: $passcode)
                SignaturePad(strokes: $strokes, language: model.language).id(generation)
                Button(t("findExisting")) { find() }.buttonStyle(.borderedProminent)
                    .disabled(busy || app.session == nil || passcode.count != 4 || strokes.flatMap { $0 }.count < 4)
                ForEach(candidates, id: \.record.id) { candidate in
                    Button { choose(candidate) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(candidate.record.id).font(.caption.monospaced())
                            Text(candidate.record.freeTextSummary).lineLimit(3)
                        }.padding(12)
                    }.buttonStyle(.bordered)
                }
            } else {
                if let record { Text(record.id).font(.caption.monospaced()) }
                if let booking {
                    Label(t("appointmentConfirmed"), systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(EdgeCareStyle.mulberry)
                    Text(displayDate(booking.startDate)).font(.title3.weight(.semibold))
                    Text(t("appointmentZone"))
                    Text(t("demoClinic"))
                    Text(t("bookingReference"))
                    Text(booking.id).font(.caption.monospaced()).textSelection(.enabled)
                    Button(t("cancelAppointment"), role: .destructive) { cancelling = true }.buttonStyle(.bordered)
                } else if loaded {
                    Text(t("demoClinic"))
                    Text(t("chooseSlot")).font(.headline)
                    if slots.isEmpty { Text(t("noAppointmentSlots")) }
                    if !slots.isEmpty {
                        Picker(t("appointmentDay"), selection: $selectedDay) {
                            ForEach(Array(Set(slots.map { String($0.startsAt.prefix(10)) })).sorted(), id: \.self) { day in
                                Text(displayDate(slots.first(where: { $0.startsAt.hasPrefix(day) })?.startDate, includeTime: false)).tag(day)
                            }
                        }.pickerStyle(.menu)
                    }
                    ForEach(slots.filter { $0.startsAt.hasPrefix(selectedDay) }) { slot in
                        Button {
                            selected = slot.id; operationID = UUID().uuidString.lowercased()
                            model.lastActivity = Date()
                        } label: {
                            HStack {
                                Text(displayDate(slot.startDate))
                                Spacer()
                                if selected == slot.id { Image(systemName: "checkmark.circle.fill") }
                            }.frame(minHeight: 48)
                        }.buttonStyle(.bordered).accessibilityAddTraits(selected == slot.id ? .isSelected : [])
                    }
                    Text(t("appointmentZone")).font(.footnote)
                    Button(t("confirmAppointment")) { book() }.buttonStyle(.borderedProminent).disabled(selected == nil)
                }
                Button(t("refreshAppointments")) { refresh() }.buttonStyle(.bordered)
            }
            if let errorKey { Text(t(errorKey)).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
            if busy { ProgressView(t("saving")) }
            Button(t(record == nil ? "cancel" : "back")) {
                clear()
                if model.record != nil { model.step = 7 } else { model.reset() }
            }.frame(minHeight: 48)
        }
        .disabled(busy)
        .tint(EdgeCareStyle.mulberry)
        .task {
            if let saved = model.record, let proof = model.appointmentVerification {
                record = saved; verification = proof; refresh()
            }
        }
        .onChange(of: selectedDay) { _, _ in selected = nil; operationID = UUID().uuidString.lowercased(); model.lastActivity = Date() }
        .onChange(of: passcode) { _, value in model.lastActivity = Date(); if !value.isEmpty { candidates = [] } }
        .onChange(of: strokes) { _, value in model.lastActivity = Date(); if !value.isEmpty { candidates = [] } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear() } }
        .onDisappear { clear() }
        .confirmationDialog(t("cancelAppointment"), isPresented: $cancelling, titleVisibility: .visible) {
            Button(t("cancelAppointment"), role: .destructive) { cancelBooking() }
            Button(t("back"), role: .cancel) {}
        }
    }
    private func displayDate(_ date: Date?, includeTime: Bool = true) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: model.language)
        formatter.timeZone = TimeZone(identifier: "Europe/Helsinki")
        formatter.dateStyle = .full; formatter.timeStyle = includeTime ? .short : .none
        return formatter.string(from: date)
    }
    private func clear() {
        generation += 1; task?.cancel(); task = nil; busy = false
        passcode = ""; strokes = []; candidates = []; record = nil; verification = nil
        slots = []; booking = nil; selected = nil; loaded = false; errorKey = nil
        operationID = UUID().uuidString.lowercased()
    }
    private func run(_ action: @escaping @MainActor (NativeSession, Int) async throws -> Void) {
        guard !busy, let session = app.session else { return }
        busy = true; errorKey = nil; model.lastActivity = Date()
        let current = generation
        task = Task {
            defer { if generation == current { busy = false; task = nil } }
            do { try await action(session, current) }
            catch {
                guard !Task.isCancelled, generation == current else { return }
                errorKey = (error as? CoreError) == .conflict ? "appointmentConflict" : "appointmentFailed"
            }
        }
    }
    private func active(_ current: Int) -> Bool { generation == current && !Task.isCancelled && scenePhase == .active }
    private func find() {
        let pin = passcode, signature = strokes
        passcode = ""; strokes = []; candidates = []; generation += 1
        run { session, current in
            let result = try await session.findReferrals(passcode: pin, strokes: signature)
            guard active(current) else { return }
            if result.matches.count == 1, let match = result.matches.first {
                record = match.record; verification = match.verification
                try await load(session, current)
            } else {
                candidates = result.matches
                if candidates.isEmpty { errorKey = result.searchedLocalOnly ? "existingNotFoundLocal" : "existingNotFound" }
            }
        }
    }
    private func choose(_ match: VerifiedReferralMatch) {
        candidates = []; record = match.record; verification = match.verification
        refresh()
    }
    private func load(_ session: NativeSession, _ current: Int) async throws {
        guard let record, let verification else { return }
        if app.wallet.contains(where: { $0.id == record.id && $0.state == .pendingEnrollment }) { await app.sync() }
        guard active(current) else { return }
        let result = try await session.appointmentAvailability(record: record, verification: verification)
        guard active(current) else { return }
        slots = result.slots; booking = result.appointment; loaded = true
        if !slots.contains(where: { $0.startsAt.hasPrefix(selectedDay) }), let first = slots.first { selectedDay = String(first.startsAt.prefix(10)) }
        if !slots.contains(where: { $0.id == selected }) { selected = nil }
    }
    private func refresh() { run { session, current in try await load(session, current) } }
    private func book() {
        guard let record, let verification, let selected else { return }
        let operation = operationID
        run { session, current in
            let confirmed = try await session.bookAppointment(record: record, verification: verification, slotID: selected, operationID: operation)
            guard active(current) else { return }
            // An idempotent retry of a cancelled operation must never look confirmed.
            guard confirmed.status == "booked" else { try await load(session, current); return }
            booking = confirmed; slots = []; self.selected = nil
        }
    }
    private func cancelBooking() {
        guard let record, let verification, let booking else { return }
        run { session, current in
            try await session.cancelAppointment(record: record, verification: verification, appointmentID: booking.id)
            guard active(current) else { return }
            self.booking = nil; loaded = false; selected = nil; operationID = UUID().uuidString.lowercased()
            try await load(session, current)
        }
    }
}
