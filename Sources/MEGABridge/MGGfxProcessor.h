#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include "megaapi.h"

/// Makes upload thumbnails and previews with ImageIO, AVFoundation and Core Graphics.
/// The SDK's own Core Graphics provider is compiled only for iOS (USE_IOS).
class MGGfxProcessor final : public mega::MegaGfxProcessor
{
public:
    ~MGGfxProcessor() override;

    bool readBitmap(const char *name, const char *path) override;
    int getWidth() override;
    int getHeight() override;
    int getBitmapDataSize(int width, int height, int px, int py, int rw, int rh, int hint) override;
    bool getBitmapData(char *bitmapData, size_t size) override;
    void freeBitmap() override;
    const char *supportedImageFormats() override;
    const char *supportedVideoFormats() override;

private:
    CGImageRef mImage = nullptr;
    NSData *mOutput = nil;
};
