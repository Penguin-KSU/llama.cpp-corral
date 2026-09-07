import AppKit

// status bar icon: pre-rendered black-on-transparent template images
// (icons/status_idle.png = outline, icons/status_loaded.png = filled),
// packaged into the app bundle by build.sh
func statusIcon(filled: Bool) -> NSImage {
    let name = filled ? "status_loaded" : "status_idle"
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
          let img = NSImage(contentsOf: url) else {
        return NSImage()
    }
    img.size = NSSize(width: 22, height: 22)   // 44px rep -> @2x
    img.isTemplate = true
    return img
}
