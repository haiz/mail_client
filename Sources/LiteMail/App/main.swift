import AppKit

let args = CommandLine.arguments

if args.contains("--ui-review") {
    let output: String
    if let idx = args.firstIndex(of: "--output"), idx + 1 < args.count {
        output = args[idx + 1]
    } else {
        output = "/tmp/ui-review"
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    let runner = UIReviewRunner(outputDir: output)
    runner.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
