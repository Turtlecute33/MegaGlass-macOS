// swift-tools-version: 6.2

import PackageDescription

// Run scripts/bootstrap.sh first. It puts the MEGA SDK and the ICU headers in Vendor/.
//
// The SDK targets follow the official MEGA SDK Package.swift (used by the MEGA iOS app),
// with two changes for macOS:
//  - ENABLE_SYNC is on. It changes the vtables of the public listener classes,
//    so every target that includes megaapi.h must use the same defines.
//  - mega/config.h is the desktop one (Vendor/config). The official package uses the iOS
//    config.h, whose USE_IOS turns on mobile transfer limits.
//  - The dependencies are built from source (scripts/build-deps.sh), not MEGA's prebuilt
//    xcframeworks (curl 8.1.2, libsodium 1.0.16, Crypto++ without hardware AES on M2+).
//  - The ICU C++ headers come from Vendor/icu and link to the system libicucore.

let sdkDefines: [CXXSetting] = [
    .define("ENABLE_SYNC"),
    .define("ENABLE_CHAT"),
    .define("HAVE_LIBUV"),
    .define("NDEBUG", .when(configuration: .release)),
    // The SDK log macros put __FILE__ in the binary: no build-machine path in it.
    .unsafeFlags(["-fmacro-prefix-map=" + Context.packageDirectory + "/="]),
]

// Static libraries built from source by scripts/build-deps.sh.
let depsLib = Context.packageDirectory + "/Vendor/deps/lib"

let package = Package(
    name: "MegaGlass",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MegaGlass", targets: ["MegaGlass"]),
        .executable(name: "megaglass-bench", targets: ["MegaGlassBench"]),
    ],
    targets: [
        .target(
            name: "MEGASdkCpp",
            path: "Vendor/mega-sdk",
            exclude: [
                "Package.swift",
                "bindings",
                "cmake",
                "contrib",
                "examples",
                "src/android",
                "src/common/client_adapter_without_sync.cpp",
                "src/common/platform/windows",
                "src/file_service/documentation",
                "src/fuse/supported",
                "third_party/utf8proc/utf8proc_data.c",
                // Not part of the SDK CMake build for desktop macOS:
                "third_party/evt-tls", // TLS for the local HTTP server (OpenSSL only)
                "src/gfx/GfxProcCG.mm", // iOS only; MEGABridge has a macOS processor
                "src/gfx/freeimage.cpp",
                "src/gfx/isolatedprocess.cpp",
                "src/gfx/worker",
                "src/posix/gfx",
                "src/posix/fdwatchset_select.cpp",
                "src/thread/cppthread.cpp",
                "src/drivenotify.cpp",
                "src/osx/drivenotifyosx.cpp",
                "src/posix/drivenotifyposix.cpp",
                "src/win32",
                "tests",
                "tools",
            ],
            cxxSettings: sdkDefines + [
                .headerSearchPath("../config"),
                .headerSearchPath("include/mega/osx"),
                .headerSearchPath("include/mega/posix"),
                .headerSearchPath("src/common/platform/posix"),
                .headerSearchPath("src/file_service"),
                .headerSearchPath("src/fuse/unsupported"),
                .headerSearchPath("third_party"),
                .headerSearchPath("../deps/include"),
                .headerSearchPath("../icu/include"),
                .define("U_DISABLE_RENAMING", to: "1"),
                .define("MEGA_USE_WSUPLOAD"),
                .define("USE_POLL"),
                .define("SUPPORTS_TI_EMULATION_MODE", to: "1"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L" + depsLib]),
                .linkedLibrary("cryptopp"),
                .linkedLibrary("curl"),
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto"),
                .linkedLibrary("sodium"),
                .linkedLibrary("uv"),
                .linkedLibrary("zstd"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Foundation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("z"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("icucore"),
            ]
        ),
        .target(
            name: "MEGASdk",
            dependencies: ["MEGASdkCpp"],
            path: "Vendor/mega-sdk/bindings/ios",
            exclude: ["3rdparty"],
            cxxSettings: sdkDefines + [
                .headerSearchPath("../../include"),
                .headerSearchPath("Private"),
            ]
        ),
        .target(
            name: "MEGABridge",
            dependencies: ["MEGASdk", "MEGASdkCpp"],
            path: "Sources/MEGABridge",
            cxxSettings: sdkDefines + [
                .headerSearchPath("../../Vendor/mega-sdk/include"),
                .headerSearchPath("../../Vendor/mega-sdk/bindings/ios/Private"),
                .headerSearchPath("../../Vendor/mega-sdk/bindings/ios/include"),
                .headerSearchPath("../../Vendor/deps/include"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .executableTarget(
            name: "MegaGlass",
            dependencies: ["MEGASdk", "MEGABridge"],
            path: "Sources/MegaGlass",
            swiftSettings: [
                // Shows the local streaming server API (MEGASdk.h, HAVE_LIBUV) to Swift.
                .unsafeFlags(["-Xcc", "-DHAVE_LIBUV"]),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "MegaGlassTests",
            dependencies: ["MegaGlass"],
            path: "Tests/MegaGlassTests",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-DHAVE_LIBUV"]),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        // Engine check without the UI: crypto speed, public link download, folder link.
        .executableTarget(
            name: "MegaGlassBench",
            dependencies: ["MEGASdk", "MEGABridge"],
            path: "Sources/MegaGlassBench"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
