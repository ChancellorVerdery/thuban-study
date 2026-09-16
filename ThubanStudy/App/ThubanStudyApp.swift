import SwiftUI
import ThubanCore

@main
struct ThubanStudyApp: App {
    var body: some Scene {
        WindowGroup("Thuban Study") {
            Text("Thuban Study \(ThubanCoreInfo.version)")
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
