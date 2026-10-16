#import "MGGfxProcessor.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <memory>
#include <mutex>
#include <cmath>

namespace {

// The SDK asks for a 1000 px preview and a 240 px thumbnail. Decoding at this size
// keeps memory low for very large photos.
constexpr CGFloat kMaxDecodeSize = 1024;

CGImageRef copyImageFrame(NSURL *url)
{
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (!source) return nullptr;
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(kMaxDecodeSize),
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

CGImageRef copyVideoFrame(NSURL *url)
{
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(kMaxDecodeSize, kMaxDecodeSize);
    generator.requestedTimeToleranceBefore = CMTimeMake(1, 1);
    generator.requestedTimeToleranceAfter = CMTimeMake(1, 1);

    struct FrameResult {
        std::mutex mutex;
        CGImageRef image = nullptr;
        ~FrameResult() { if (image) CGImageRelease(image); }
    };
    auto result = std::make_shared<FrameResult>();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [generator generateCGImageAsynchronouslyForTime:CMTimeMake(1, 1)
                                  completionHandler:^(CGImageRef image, CMTime, NSError *) {
        std::lock_guard<std::mutex> guard(result->mutex);
        if (image) result->image = CGImageRetain(image);
        dispatch_semaphore_signal(done);
    }];
    // Runs on the SDK graphics thread, never on the main thread.
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0) {
        [generator cancelAllCGImageGeneration];
        return nullptr;
    }
    std::lock_guard<std::mutex> guard(result->mutex);
    return result->image ? CGImageRetain(result->image) : nullptr;
}

CGImageRef copyPDFFrame(NSURL *url)
{
    CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    if (!document) return nullptr;
    CGImageRef image = nullptr;
    if (CGPDFPageRef page = CGPDFDocumentGetPage(document, 1))
    {
        CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
        if (!std::isfinite(box.size.width) || !std::isfinite(box.size.height) ||
            box.size.width <= 0 || box.size.height <= 0) {
            CGPDFDocumentRelease(document);
            return nullptr;
        }
        CGFloat scale = kMaxDecodeSize / MAX(box.size.width, box.size.height);
        size_t width = (size_t)MAX(1.0, round(box.size.width * scale));
        size_t height = (size_t)MAX(1.0, round(box.size.height * scale));
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(nullptr, width, height, 8, 0, space,
                                                     (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        CGColorSpaceRelease(space);
        if (context)
        {
            CGContextSetRGBFillColor(context, 1, 1, 1, 1);
            CGContextFillRect(context, CGRectMake(0, 0, width, height));
            CGContextScaleCTM(context, scale, scale);
            CGContextTranslateCTM(context, -box.origin.x, -box.origin.y);
            CGContextDrawPDFPage(context, page);
            image = CGBitmapContextCreateImage(context);
            CGContextRelease(context);
        }
    }
    CGPDFDocumentRelease(document);
    return image;
}

// Reads a premultiplied RGBA context: true when a pixel is not fully opaque.
bool hasTransparentPixels(CGContextRef context)
{
    const uint8_t *pixels = (const uint8_t *)CGBitmapContextGetData(context);
    if (!pixels) return true;
    size_t width = CGBitmapContextGetWidth(context);
    size_t height = CGBitmapContextGetHeight(context);
    size_t stride = CGBitmapContextGetBytesPerRow(context);
    for (size_t y = 0; y < height; ++y)
    {
        const uint8_t *row = pixels + y * stride;
        for (size_t x = 0; x < width; ++x)
        {
            if (row[x * 4 + 3] != 255) return true;
        }
    }
    return false;
}

} // namespace

MGGfxProcessor::~MGGfxProcessor()
{
    freeBitmap();
}

bool MGGfxProcessor::readBitmap(const char *name, const char *path)
{
    freeBitmap();
    if (!path) return false;
    @autoreleasepool
    {
        NSString *extension = [NSString stringWithUTF8String:name ?: ""].pathExtension.lowercaseString;
        NSString *localPath = [NSString stringWithUTF8String:path];
        if (!localPath) return false;
        NSURL *url = [NSURL fileURLWithPath:localPath];
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if ([type conformsToType:UTTypePDF])
        {
            mImage = copyPDFFrame(url);
        }
        else if ([type conformsToType:UTTypeAudiovisualContent])
        {
            mImage = copyVideoFrame(url);
        }
        else
        {
            mImage = copyImageFrame(url);
        }
    }
    return mImage != nullptr;
}

int MGGfxProcessor::getWidth()
{
    return mImage ? (int)CGImageGetWidth(mImage) : 0;
}

int MGGfxProcessor::getHeight()
{
    return mImage ? (int)CGImageGetHeight(mImage) : 0;
}

int MGGfxProcessor::getBitmapDataSize(int width, int height, int px, int py, int rw, int rh, int hint)
{
    mOutput = nil;
    if (!mImage || width <= 0 || height <= 0 || rw <= 0 || rh <= 0) return 0;

    @autoreleasepool
    {
        // The SDK allows PNG for every thumbnail. As in the SDK's FreeImage processor, only
        // transparent images use it: opaque photos are much smaller as JPEG.
        CGImageAlphaInfo alpha = CGImageGetAlphaInfo(mImage);
        BOOL png = hint == GFX_HINT_FORMAT_PNG && alpha != kCGImageAlphaNone
            && alpha != kCGImageAlphaNoneSkipLast && alpha != kCGImageAlphaNoneSkipFirst;
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(nullptr, (size_t)rw, (size_t)rh, 8, 0, space,
                                                     (CGBitmapInfo)(png ? kCGImageAlphaPremultipliedLast
                                                                        : kCGImageAlphaNoneSkipLast));
        CGColorSpaceRelease(space);
        if (!context) return 0;

        // The SDK gives (px, py) from the top-left corner of the scaled image.
        // Core Graphics uses a bottom-left origin.
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(-px, py + rh - height, width, height), mImage);
        // Some decoders (HEIC) give an alpha channel also for opaque photos.
        if (png && !hasTransparentPixels(context)) png = NO;
        CGImageRef result = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        if (!result) return 0;

        NSMutableData *data = [NSMutableData data];
        CFStringRef format = (__bridge CFStringRef)(png ? UTTypePNG.identifier : UTTypeJPEG.identifier);
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, format, 1, nullptr);
        if (destination)
        {
            NSDictionary *properties = @{(id)kCGImageDestinationLossyCompressionQuality: @0.85};
            CGImageDestinationAddImage(destination, result, (__bridge CFDictionaryRef)properties);
            if (CGImageDestinationFinalize(destination)) mOutput = data;
            CFRelease(destination);
        }
        CGImageRelease(result);
    }
    return mOutput ? (int)mOutput.length : 0;
}

bool MGGfxProcessor::getBitmapData(char *bitmapData, size_t size)
{
    if (!mOutput || size < mOutput.length) return false;
    memcpy(bitmapData, mOutput.bytes, mOutput.length);
    return true;
}

void MGGfxProcessor::freeBitmap()
{
    if (mImage)
    {
        CGImageRelease(mImage);
        mImage = nullptr;
    }
    mOutput = nil;
}

const char *MGGfxProcessor::supportedImageFormats()
{
    // The SDK makes thumbnails and previews only for these names. readBitmap sends the
    // videos to AVFoundation.
    return ".jpg.jpeg.jpe.png.gif.bmp.tif.tiff.heic.heif.hif.webp.avif.jp2.j2k.psd.ico.icns.tga.exr.pdf."
           "dng.cr2.cr3.crw.nef.nrw.arw.srf.sr2.raf.orf.rw2.pef.srw.3fr.erf.mrw.raw."
           "mp4.m4v.mov.3gp.3g2.";
}

const char *MGGfxProcessor::supportedVideoFormats()
{
    return ".mp4.m4v.mov.3gp.3g2.";
}
