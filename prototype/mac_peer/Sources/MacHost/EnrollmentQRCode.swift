import CoreGraphics
import CoreImage
import Foundation

/// 把手机登记码画成二维码，iPhone App 详情里「扫码登记」扫它。内容就是登记码本身（和手动复制的一样），只在本机登记窗口里显示
public enum EnrollmentQRCode {
    /// 白底、四周留 4 格空白，放大时不插值，深色模式下手机隔着屏幕也好扫
    public static func cgImage(for text: String, moduleSize: Int = 12) -> CGImage? {
        guard moduleSize > 0, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let modules = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let quiet = 4
        let side = (max(modules.width, modules.height) + quiet * 2) * moduleSize
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(modules, in: CGRect(x: quiet * moduleSize, y: quiet * moduleSize,
                                         width: modules.width * moduleSize, height: modules.height * moduleSize))
        return context.makeImage()
    }
}
