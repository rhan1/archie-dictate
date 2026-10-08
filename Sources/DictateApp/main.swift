import AppKit
import DictateAppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // LSUIElement: no Dock icon, never steals focus
let controller = AppController()
controller.start()
app.run()
