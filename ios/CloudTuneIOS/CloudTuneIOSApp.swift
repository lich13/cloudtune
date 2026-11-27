import CloudTuneCore
import CloudTuneUI
import SwiftUI

@main
struct CloudTuneIOSApp: App {
    @State private var viewModel = CloudTuneViewModel()

    var body: some Scene {
        WindowGroup {
            IOSRootView(viewModel: viewModel)
                .task {
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
                        return
                    }
                    await viewModel.bootstrap()
                }
        }
    }
}
