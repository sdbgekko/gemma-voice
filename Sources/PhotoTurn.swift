import UIKit

/// Client-side photo processing for photo turns (0.2.45).
///
/// The picker hands us whatever the library holds (HEIC, PNG, JPEG…); the
/// server only accepts JPEG/PNG magic bytes and caps uploads at 10MB, so we
/// normalize everything here: downscale so the longest edge is at most
/// `maxEdge` pixels, re-encode as JPEG at `jpegQuality`, and ship that as
/// base64 inside the /text_turn body (covered by the existing body HMAC).
/// 1568px is the sweet spot for vision-model reads — bigger buys no accuracy,
/// just latency and upload weight.
enum PhotoTurn {
    static let maxEdge: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.8

    /// Downscale + JPEG-encode an image for upload. Returns nil only if
    /// encoding fails (CGImage-less UIImage, zero size). HEIC transcoding is
    /// implicit — decode to UIImage, encode to JPEG.
    static func jpegForUpload(_ image: UIImage) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scaled: UIImage
        if longest > maxEdge {
            let scale = maxEdge / longest
            let target = CGSize(width: max(1, floor(size.width * scale)),
                                height: max(1, floor(size.height * scale)))
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale = 1   // render in raw pixels so the 1568 cap is real pixels
            scaled = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        } else {
            scaled = image
        }
        return scaled.jpegData(compressionQuality: jpegQuality)
    }
}
