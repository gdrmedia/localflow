import Foundation

/// Tiny local IPC: lets `localflow-cli --settings` (or any script) ask the running app to show its
/// Settings window. Distributed notifications never leave the machine.
public enum LocalFlowIPC {
    public static let openSettings = Notification.Name("com.gdrmedia.localflow.openSettings")

    public static func postOpenSettings() {
        DistributedNotificationCenter.default().postNotificationName(openSettings, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
