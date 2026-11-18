import AppKit

enum BallArtwork {
    /// Same spherical lighting as Windows white_art, cached by the caller.
    @MainActor static func cue(texture: NSImage?) -> NSImage {
        let side = 192
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
            colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        var textureBitmap: NSBitmapImageRep?
        if let texture {
            let source = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,
                bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:source)
            texture.draw(in:NSRect(x:0,y:0,width:side,height:side)); NSGraphicsContext.restoreGraphicsState()
            textureBitmap = source
        }
        let bytes = bitmap.bitmapData!
        for py in 0..<side { for px in 0..<side {
            let x = (Double(px)+0.5)/Double(side)*2-1, y = (Double(py)+0.5)/Double(side)*2-1
            let z2 = 1-x*x-y*y, index = py*bitmap.bytesPerRow+px*4
            guard z2 > 0 else { bytes[index+3] = 0; continue }
            let light = max(0,-0.46*x-0.49*y+0.74*sqrt(z2))
            let shine = exp(-((x+0.34)*(x+0.34)+(y+0.40)*(y+0.40))/0.038)
            let components: [Double]
            if let color = textureBitmap?.colorAt(x:px,y:py)?.usingColorSpace(.deviceRGB) {
                components = [color.redComponent,color.greenComponent,color.blueComponent].map { Double($0)*255*(0.78+0.22*light)+20*shine }
            } else {
                let value = 157+96*light+32*shine
                components = [value,value+4,value+9]
            }
            for channel in 0..<3 { bytes[index+channel] = UInt8(min(255,max(0,components[channel].rounded()))) }
            bytes[index+3] = 255
        } }
        let image = NSImage(size:NSSize(width:side,height:side)); image.addRepresentation(bitmap); return image
    }
}
