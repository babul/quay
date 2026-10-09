## Build commands

**First-time setup** (requires Xcode 16+, `zig` 0.16.x, `xcodegen`):
```sh
./scripts/bootstrap.sh
open Quay.xcodeproj
```

**Regenerate Xcode project** (after changing `project.yml`):
```sh
xcodegen generate
```

**Run tests:**
```sh
xcodebuild -project Quay.xcodeproj -scheme Quay -configuration Debug -destination 'platform=macOS' test
```

**Run a single test suite** (e.g., SSHCommandBuilderTests):
```sh
xcodebuild -project Quay.xcodeproj -scheme Quay -configuration Debug -destination 'platform=macOS' test -only-testing:QuayTests/SSHCommandBuilderTests
```

**Rebuild libghostty** (only needed when bumping the ghostty submodule):
```sh
./scripts/build-ghostty.sh
```

**Check `AGENTS.md` is current** (before committing any change under `.ai/guidelines/`; there is no
pre-commit hook, so this is the gate):
```sh
scripts/agents.sh check
```

The Xcode project is gitignored and generated from `project.yml` by XcodeGen. Never edit `.xcodeproj` files directly.
