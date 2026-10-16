# Native security updates

The curl, OpenSSL, libsodium, and zlib overlay ports are copied from Microsoft vcpkg commit
`357b1a6f8343064ca982a20771e420fcecfe7efc` (MIT license), the same ports as in MegaGlass-Android.
They select curl 8.23.0, OpenSSL 3.6.5#1, libsodium 1.0.22#1, and zlib 1.3.2#2, with the
upstream download checksums and patches. One change: `openssl/unix/portfile.cmake` sets
ENGINESDIR and MODULESDIR to system folders, so libcrypto does not contain the install folder
of the build machine. The remaining dependencies stay pinned by the SDK manifest baseline.
SQLite comes from macOS.

The SDK's original baseline selected curl 8.14.1 with Apple Secure Transport. curl 8.14.1 has
subsequently published security advisories, and curl 8.15.0 removed Secure Transport. curl now
uses OpenSSL for TLS (TLS 1.3 too) and the macOS trust store for certificates
(`USE_APPLE_SECTRUST`). The SDK pins the MEGA API public key with `CURLOPT_PINNEDPUBLICKEY`,
which OpenSSL supports.

`scripts/build-deps.sh` puts these ports before the SDK ports, checks the installed versions,
and rebuilds when a port changes. These are pinned versions: they do not update by themselves.

Sources: [vcpkg revision](https://github.com/microsoft/vcpkg/tree/357b1a6f8343064ca982a20771e420fcecfe7efc/ports),
[curl advisories](https://curl.se/docs/vuln-8.14.1.html),
[OpenSSL advisories](https://www.openssl-library.org/news/vulnerabilities/index.html),
[libsodium releases](https://github.com/jedisct1/libsodium/releases), and
[zlib releases](https://zlib.net/).
