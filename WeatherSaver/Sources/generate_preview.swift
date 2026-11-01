#!/usr/bin/swift
import Cocoa
import ScreenSaver

let frame = NSRect(x: 0, y: 0, width: 288, height: 162)
let view = WeatherSaverView(frame: frame, isPreview: true)!
view.animateOneFrame()

let image = NSImage(size: frame.size)
image.lockFocus()
view.draw(view.bounds)
image.unlockFocus()

if let tiffData = image.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    let url = URL(fileURLWithPath: "/Users/dirk/Projekte/xcode/weather_saver/WeatherSaver/Sources/preview.png")
    try pngData.write(to: url)
    print("Preview image saved to \(url.path)")
} else {
    print("Failed to generate preview")
    exit(1)
}