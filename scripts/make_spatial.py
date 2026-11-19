import sys

import Quartz
from Foundation import NSURL

mono, left, right, target = sys.argv[1:5]
destination = Quartz.CGImageDestinationCreateWithURL(NSURL.fileURLWithPath_(target), "public.heic", 3, None)
group = {
    Quartz.kCGImagePropertyGroupIndex: 0,
    Quartz.kCGImagePropertyGroupType: Quartz.kCGImagePropertyGroupTypeStereoPair,
    Quartz.kCGImagePropertyGroupImageIndexMonoscopic: 0,
    Quartz.kCGImagePropertyGroupImageIndexLeft: 1,
    Quartz.kCGImagePropertyGroupImageIndexRight: 2,
    Quartz.kCGImagePropertyGroupImageBaseline: 80000,
    Quartz.kCGImagePropertyGroupImageDisparityAdjustment: 200,
}
roles = [
    Quartz.kCGImagePropertyGroupImageIsMonoscopicImage,
    Quartz.kCGImagePropertyGroupImageIsLeftImage,
    Quartz.kCGImagePropertyGroupImageIsRightImage,
]
for path, role in zip([mono, left, right], roles):
    source = Quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(path), None)
    image = Quartz.CGImageSourceCreateImageAtIndex(source, 0, None)
    Quartz.CGImageDestinationAddImage(destination, image, {Quartz.kCGImagePropertyGroups: group | {role: True}})
if not Quartz.CGImageDestinationFinalize(destination):
    sys.exit("cannot write the spatial photo")
