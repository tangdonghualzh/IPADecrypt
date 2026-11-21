// 生成 App 图标：青绿渐变底 + 白色纸箱 + 绿色圆形徽标里的白色开锁。
// 用法：swiftc scripts/makeicon.swift -o /tmp/makeicon -framework AppKit && /tmp/makeicon
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// 版式比例（相对画布边长），来自旧图标的像素测量。
let boxInkHeight: CGFloat = 0.539
let boxCenter = CGPoint(x: 0.497, y: 0.436)      // 以左上角为原点
let badgeCenter = CGPoint(x: 0.737, y: 0.742)     // 内收，避免被 iOS 圆角遮罩切掉
let badgeRadius: CGFloat = 0.148
let lockInkHeight: CGFloat = 0.195                 // 圆圈直径的 ~66%

// 沿用旧图标自带的 ICC 配置，避免换色。
let iccURL = root.appendingPathComponent("assets/icon-profile.icc")
let colorSpace = (try? Data(contentsOf: iccURL)).flatMap { CGColorSpace(iccData: $0 as CFData) }
    ?? CGColorSpace(name: CGColorSpace.sRGB)!

func paint(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, 1])!
}

let bgStart = paint(53/255, 135/255, 139/255)
let bgEnd = paint(24/255, 65/255, 73/255)
let badgeGreen = paint(72/255, 162/255, 112/255)

struct IconSpec {
    let file: String
    let pixels: Int
}

let specs: [IconSpec] = [
    .init(file: "AppIcon29x29@3x.png", pixels: 87),
    .init(file: "AppIcon40x40@3x.png", pixels: 120),
    .init(file: "AppIcon60x60@2x.png", pixels: 120),
    .init(file: "AppIcon60x60@3x.png", pixels: 180),
    .init(file: "AppIcon76x76@2x~ipad.png", pixels: 152),
    .init(file: "AppIcon83x83@2x~ipad.png", pixels: 166),
]

func makeContext(_ pixels: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("无法创建绘图上下文")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// 把 SF Symbol 画进透明画布，返回裁到实际墨迹的白色图像与墨迹尺寸。
func symbolLayer(_ name: String, weight: NSFont.Weight, pointSize: CGFloat, canvas: Int) -> (CGImage, CGRect)? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) else {
        return nil
    }
    let ctx = makeContext(canvas)
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var minX = canvas, minY = canvas, maxX = -1, maxY = -1
    for y in 0..<canvas {
        let row = data.advanced(by: y * ctx.bytesPerRow)
        for x in 0..<canvas {
            let alpha = row[x * 4 + 3]
            if alpha > 12 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let ink = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)

    // 统一涂白（premultipliedLast：R=G=B=A）。
    for y in 0..<canvas {
        let row = data.advanced(by: y * ctx.bytesPerRow)
        for x in 0..<canvas {
            let p = x * 4
            let alpha = row[p + 3]
            if alpha > 0 {
                row[p] = alpha
                row[p + 1] = alpha
                row[p + 2] = alpha
            }
        }
    }
    guard let full = ctx.makeImage(), let cropped = full.cropping(to: ink) else { return nil }
    return (cropped, ink)
}

func drawSymbol(_ name: String, weight: NSFont.Weight, inkHeight: CGFloat, center: CGPoint, in ctx: CGContext, canvas: Int) {
    guard let (image, ink) = symbolLayer(name, weight: weight, pointSize: CGFloat(canvas) * 0.5, canvas: canvas) else { return }
    let scale = inkHeight / ink.height
    let size = CGSize(width: ink.width * scale, height: ink.height * scale)
    let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    ctx.draw(image, in: rect)
}

func render(_ pixels: Int) -> CGImage {
    let s = CGFloat(pixels)
    let ctx = makeContext(pixels)

    let gradient = CGGradient(colorsSpace: colorSpace, colors: [bgStart, bgEnd] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: s, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // 左上角为原点的坐标转成 CG 的左下角坐标。
    let boxPoint = CGPoint(x: boxCenter.x * s, y: (1 - boxCenter.y) * s)
    drawSymbol("shippingbox.fill", weight: .semibold, inkHeight: boxInkHeight * s, center: boxPoint, in: ctx, canvas: pixels)

    let badgePoint = CGPoint(x: badgeCenter.x * s, y: (1 - badgeCenter.y) * s)
    let radius = badgeRadius * s
    ctx.setFillColor(badgeGreen)
    ctx.fillEllipse(in: CGRect(x: badgePoint.x - radius, y: badgePoint.y - radius,
                               width: radius * 2, height: radius * 2))

    drawSymbol("lock.open.fill", weight: .bold, inkHeight: lockInkHeight * s, center: badgePoint, in: ctx, canvas: pixels)

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("无法写入 \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG 写入失败 \(url.path)") }
}

for spec in specs {
    write(render(spec.pixels), to: root.appendingPathComponent("src/\(spec.file)"))
    print("src/\(spec.file)  \(spec.pixels)px")
}
write(render(1024), to: root.appendingPathComponent("assets/icon-master.png"))
print("assets/icon-master.png  1024px")
