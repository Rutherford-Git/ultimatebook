import SwiftUI

@main
struct InkbookApp: App {
    @StateObject private var library: LibraryStore

    init() {
        AppDiagnostics.start()   // before anything else, so early errors are captured
        _library = StateObject(wrappedValue: LibraryStore())
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
        }
    }
}
