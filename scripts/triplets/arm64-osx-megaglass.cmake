# Same as the SDK arm64-osx-mega triplet, but release-only (the app links only the release libs).
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_BUILD_TYPE release)

set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 11.1)
# scripts/build-deps.sh selects the SDK. It is part of the package ABI (binary cache).
set(VCPKG_ENV_PASSTHROUGH SDKROOT)

set(VCPKG_C_FLAGS "-mmacosx-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}")
set(VCPKG_CXX_FLAGS "-mmacosx-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}")
set(VCPKG_LINKER_FLAGS "-mmacosx-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}")

# No build-machine path in __FILE__ in the libraries. Not for OpenSSL: it builds from relative
# paths, and it copies these flags into its version string.
if(NOT PORT STREQUAL "openssl")
    get_filename_component(_megaglass_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
    string(APPEND VCPKG_C_FLAGS " -fmacro-prefix-map=${_megaglass_root}/=")
    string(APPEND VCPKG_CXX_FLAGS " -fmacro-prefix-map=${_megaglass_root}/=")
endif()
