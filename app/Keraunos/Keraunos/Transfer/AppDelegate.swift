import UIKit

/// Hosts the one app-delegate hook a background `URLSession` requires: iOS relaunches the app
/// to finish transfer events and hands us a completion handler that must be called once the
/// session's event queue drains. We route it to the shared transfer engine.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTransferService.backgroundIdentifier else {
            completionHandler()
            return
        }
        // The engine wires the delegate and recreates the session (launch ordering); the
        // handler is invoked from `urlSessionDidFinishEvents` once events drain.
        TransferEngine.shared.handleBackgroundEvents(completion: completionHandler)
    }
}
