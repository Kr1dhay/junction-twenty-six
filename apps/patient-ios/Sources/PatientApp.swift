import SwiftUI
import EdgeCareCore
import EdgeCareUI
@main struct PatientApp: App {
    @State private var model = PatientViewModel()
    var body: some Scene { WindowGroup { PatientRootView(model: model) } }
}
@MainActor @Observable final class PatientViewModel {
    let configuration = AppConfiguration.demo
    let intake = IntakeViewModel()
}
struct PatientRootView: View {
    @Bindable var model: PatientViewModel
    var body: some View {
        TabView {
            NavigationStack { IntakeView(title: "Edge-Care", model: model.intake) }
                .tabItem { Label("New concern", systemImage: "bubble.left") }
            NavigationStack {
                ContentUnavailableView("Your referral wallet", systemImage: "wallet.pass", description: Text("Encrypted wallet storage and referral hand-off are the next integration slice."))
                    .navigationTitle("Referrals")
            }.tabItem { Label("Wallet", systemImage: "wallet.pass") }
        }
    }
}
