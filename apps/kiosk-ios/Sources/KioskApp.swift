import SwiftUI
import EdgeCareCore
import EdgeCareUI
@main struct KioskApp: App {
    @State private var model = KioskViewModel()
    var body: some Scene { WindowGroup { KioskRootView(model: model) } }
}
@MainActor @Observable final class KioskViewModel {
    let configuration = AppConfiguration.demo
    let intake = IntakeViewModel()
}
struct KioskRootView: View {
    @Bindable var model: KioskViewModel
    var body: some View {
        NavigationStack { IntakeView(title: "Welcome to Edge-Care", model: model.intake) }
    }
}
