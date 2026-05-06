// Quay-Bridging-Header.h
//
// Once `scripts/build-ghostty.sh` produces `Frameworks/GhosttyKit.xcframework`,
// this header re-exports the libghostty C API to Swift via the framework's
// modular header.
//
// Until then, this file is intentionally empty so the app builds without the
// xcframework present.

#if __has_include(<GhosttyKit/ghostty.h>)
#import <GhosttyKit/ghostty.h>
#endif

#import <CommonCrypto/CommonCrypto.h>
