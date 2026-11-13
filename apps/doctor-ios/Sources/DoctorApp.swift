import SwiftUI
import EdgeCareCore
@main struct DoctorApp: App {
    @State private var model = DoctorViewModel()
    var body: some Scene { WindowGroup { DoctorRootView(model: model) } }
}
@MainActor @Observable final class DoctorViewModel {
    var referrals: [ReferralRecord] = []
    var error: String?
    let configuration = AppConfiguration.demo
    func load() {
        do { referrals = try DemoData.referrals() }
        catch { self.error = "Demo fixtures could not be loaded." }
    }
}
struct DoctorRootView: View {
    @Bindable var model: DoctorViewModel
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Local synthetic demo · brand placeholder") }
                if let error = model.error { Text(error) }
                Section("Select an anonymous referral") {
                    ForEach(model.referrals) { record in
                        NavigationLink {
                            Form {
                                Section("Referral") { Text(record.id); Text(record.freeTextSummary) }
                                Section("Verification · next slice") {
                                    Text("The shared verification service supports decryption, signature matching, commitment checks and single-use spending.")
                                    Text("Passcode entry, signature capture and clinician signing still need to be connected to this screen.")
                                    Text("Offline verification is provisional until synchronized with the shared registry.")
                                }
                            }.navigationTitle("Verify referral")
                        } label: {
                            VStack(alignment: .leading) {
                                Text(String(record.id.prefix(8))).font(.headline)
                                Text(record.recommendedSpecialty); Text(record.riskBand.rawValue + " risk · demo only").font(.caption)
                            }
                        }
                    }
                }
            }.navigationTitle("Doctor verification").task { model.load() }
        }
    }
}
