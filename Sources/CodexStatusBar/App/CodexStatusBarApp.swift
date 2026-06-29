import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct CodexStatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = CodexStatusStore()

    var body: some Scene {
        MenuBarExtra {
            StatusPanelView()
                .environmentObject(store)
                .frame(width: 360)
        } label: {
            StatusBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct StatusBarLabel: View {
    @EnvironmentObject private var store: CodexStatusStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.65)) { context in
            let shouldDim = store.needsUserAttention
                && Int(context.date.timeIntervalSinceReferenceDate / 0.65).isMultiple(of: 2)

            HStack(spacing: 0) {
                Text(store.statusBarTaskText)
                    .opacity(shouldDim ? 0.25 : 1)
                Text(" | \(store.statusBarQuotaText)")
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }
}
