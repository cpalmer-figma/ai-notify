import AppKit
import SwiftUI

@main
@MainActor
struct CoderNotifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Label {
                if let count = model.snapshot?.attentionCount, count > 0 { Text("\(count)") }
            } icon: {
                Image(nsImage: MenuBarIcon.image(symbolName: model.displayError != nil ? "bell.slash" :
                        (model.snapshot?.attentionCount ?? 0) > 0 ? "bell.badge.fill" : "bell"))
                    .accessibilityLabel("Coder Notify")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) { Self.model?.shutdown() }
}
