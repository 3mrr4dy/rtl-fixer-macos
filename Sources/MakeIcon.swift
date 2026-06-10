import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "RTLViewerIcon.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.16, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.31, blue: 0.35, alpha: 1),
])!
bg.draw(in: rect, angle: 135)

let rounded = NSBezierPath(roundedRect: rect.insetBy(dx: 70, dy: 70), xRadius: 180, yRadius: 180)
NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
rounded.fill()

let panel = NSBezierPath(roundedRect: NSRect(x: 150, y: 210, width: 724, height: 560), xRadius: 72, yRadius: 72)
NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
panel.fill()

NSColor(calibratedRed: 0.02, green: 0.12, blue: 0.15, alpha: 1).setFill()
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

let rtlAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 210, weight: .black),
    .foregroundColor: NSColor(calibratedRed: 0.02, green: 0.12, blue: 0.15, alpha: 1),
    .paragraphStyle: paragraph,
]
("RTL" as NSString).draw(in: NSRect(x: 150, y: 445, width: 724, height: 240), withAttributes: rtlAttrs)

let arabicAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 150, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.02, green: 0.40, blue: 0.42, alpha: 1),
    .paragraphStyle: paragraph,
]
("عربي" as NSString).draw(in: NSRect(x: 150, y: 300, width: 724, height: 175), withAttributes: arabicAttrs)

let arrowAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 110, weight: .heavy),
    .foregroundColor: NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.16, alpha: 1),
    .paragraphStyle: paragraph,
]
("←" as NSString).draw(in: NSRect(x: 150, y: 185, width: 724, height: 130), withAttributes: arrowAttrs)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Could not render icon")
}

try png.write(to: URL(fileURLWithPath: output))
