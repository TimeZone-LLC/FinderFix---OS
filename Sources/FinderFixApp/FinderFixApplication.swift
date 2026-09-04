import AppKit

@main
enum FinderFixApplication {
    @MainActor
    static func main() {
        let application: NSApplication = NSApplication.shared
        let delegate: FinderFixAppDelegate = FinderFixAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
