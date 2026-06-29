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
            Text(store.statusBarText)
                .font(.system(size: 12, design: .monospaced))
                .opacity(store.needsUserAttention && store.isAttentionDimmed ? 0.25 : 1)
        }
        .menuBarExtraStyle(.window)
    }
}
