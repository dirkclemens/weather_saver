import AppKit
import ScreenSaver

final class PreviewWindowController: NSWindowController {

    private let screenSaverView: WeatherSaverView

    convenience init() {
        let frame = NSRect(x: 0, y: 0, width: 2000, height: 1300)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WeatherSaver Preview"
        window.backgroundColor = NSColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1.0)
        window.isOpaque = true

        self.init(window: window)
    }

    override init(window: NSWindow?) {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        guard let view = WeatherSaverView(frame: frame, isPreview: false) else {
            fatalError("Failed to create WeatherSaverView")
        }
        self.screenSaverView = view
        super.init(window: window)
        setupView()
    }

    required init?(coder: NSCoder) {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        guard let view = WeatherSaverView(frame: frame, isPreview: false) else {
            fatalError("Failed to create WeatherSaverView")
        }
        self.screenSaverView = view
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        guard let window = window else { 
            return 
        }
        
        screenSaverView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1000, height: 650)
        screenSaverView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(screenSaverView)

        Timer.scheduledTimer(timeInterval: screenSaverView.animationTimeInterval, target: screenSaverView, selector: #selector(WeatherSaverView.animateOneFrame), userInfo: nil, repeats: true)
        screenSaverView.startAnimation()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func showPreferences(_ sender: NSObject?) {
        guard let sheet = screenSaverView.configureSheet, let window = window else { return }

        window.beginSheet(sheet) { _ in
            sheet.close()
        }
    }
}
