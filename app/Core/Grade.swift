import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

struct Grade: Codable, Equatable {
    var look = "none"
    var exposure = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var warmth = 0.0
    var vignette = 0.0
}

let filmLooks: [(id: String, title: String, filter: String?)] = [
    ("none", String(localized: "Оригинал"), nil),
    ("chrome", "Chrome", "CIPhotoEffectChrome"),
    ("fade", "Fade", "CIPhotoEffectFade"),
    ("instant", "Instant", "CIPhotoEffectInstant"),
    ("process", "Process", "CIPhotoEffectProcess"),
    ("transfer", "Transfer", "CIPhotoEffectTransfer"),
    ("tonal", "Tonal", "CIPhotoEffectTonal"),
    ("mono", "Mono", "CIPhotoEffectMono"),
    ("noir", "Noir", "CIPhotoEffectNoir"),
]

private let gradeContext = CIContext()

func apply(_ grade: Grade, to source: CGImage) -> CGImage {
    var image = CIImage(cgImage: source)
    let extent = image.extent
    let exposure = CIFilter.exposureAdjust()
    exposure.inputImage = image
    exposure.ev = Float(grade.exposure)
    image = exposure.outputImage ?? image
    let warmth = CIFilter.colorMatrix()
    warmth.inputImage = image
    warmth.rVector = CIVector(x: 1 + 0.15 * grade.warmth, y: 0, z: 0, w: 0)
    warmth.bVector = CIVector(x: 0, y: 0, z: 1 - 0.15 * grade.warmth, w: 0)
    image = warmth.outputImage ?? image
    if let name = filmLooks.first(where: { $0.id == grade.look })?.filter, let look = CIFilter(name: name) {
        look.setValue(image, forKey: kCIInputImageKey)
        image = look.outputImage ?? image
    }
    let controls = CIFilter.colorControls()
    controls.inputImage = image
    controls.contrast = Float(grade.contrast)
    controls.saturation = Float(grade.saturation)
    image = controls.outputImage ?? image
    if grade.vignette > 0 {
        let vignette = CIFilter.vignette()
        vignette.inputImage = image
        vignette.intensity = Float(grade.vignette * 2)
        vignette.radius = Float(max(extent.width, extent.height) / 2)
        image = vignette.outputImage ?? image
    }
    return gradeContext.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? source
}

func graded(_ wiggle: Wiggle, grade: Grade) -> Wiggle {
    guard grade != Grade() else { return wiggle }
    return Wiggle(
        steps: wiggle.steps.map { apply(grade, to: $0) }, keyframes: wiggle.keyframes, crop: wiggle.crop,
        workingSize: wiggle.workingSize)
}
