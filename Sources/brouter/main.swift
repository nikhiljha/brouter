import AppKit

let rawArgs = Array(CommandLine.arguments.dropFirst())

// Preview the Ask dialog without being the default browser.
if rawArgs.first == "ask-demo" {
    Demo.run()
}

// CLI subcommands run and exit; otherwise we launch as the agent.
if let code = CLI.run(rawArgs) {
    exit(code)
}

let app = NSApplication.shared
// Retain the delegate (NSApplication.delegate is weak).
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory) // background agent, no Dock icon
app.run()
