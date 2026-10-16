# Generates mega/config.h for a desktop macOS build, with the values that the
# MEGA SDK CMake build uses (sdklib_variables.cmake, sdklib_libraries.cmake).
# The iOS config.h in bindings/ios defines USE_IOS, which turns on mobile limits
# (fewer connections, 2 MB requests), so it is not used here.
# Usage: cmake -DSDK_DIR=... -DOUT_DIR=... -P macos-config.cmake
set(ENABLE_CHAT 1)
set(ENABLE_SYNC 1)
set(HAVE_DIRENT_H 1)
set(HAVE_DISTINCT_TIME_T 1)
set(HAVE_INTTYPES_H 1)
set(HAVE_LIBUV 1)
set(NO_READLINE 1)
set(USE_SQLITE 1)
set(USE_SODIUM 1)
set(USE_CRYPTOPP 1)
set(USE_PTHREAD 1)
# USE_OPENSSL stays off, as in the SDK CMake build for Apple. curl does the TLS (with OpenSSL)
# and pins the API key with CURLOPT_PINNEDPUBLICKEY. USE_OPENSSL would also turn on the HTTPS
# local server (third_party/evt-tls), which Package.swift leaves out.
configure_file("${SDK_DIR}/cmake/config.h.in" "${OUT_DIR}/mega/config.h")
