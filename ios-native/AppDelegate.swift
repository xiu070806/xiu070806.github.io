
import UIKit
import WebKit
import CoreLocation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var locationService: NativeLocationService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let controller = ViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        locationService = NativeLocationService()
        locationService?.attach(webView: controller.webView)
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        locationService?.appDidEnterBackground()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        locationService?.appWillEnterForeground()
    }
}
