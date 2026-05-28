import AppKit

@main
enum MixedCaptureAudioMain {
    private static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        AppCommandMenu.install(on: app)
        app.delegate = appDelegate
        app.run()
    }
}
