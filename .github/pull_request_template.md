## Summary

<!-- What does this change do, and why? -->

## Area

<!-- Which part of the system? -->
- [ ] Desktop app (`apps/desktop`)
- [ ] Engine (`engine`)
- [ ] IPC protocol (`packages/protocol` + both sides)
- [ ] Docs / scripts / tooling

## Checklist

- [ ] `./scripts/check.sh` passes (fmt + lint, both sides)
- [ ] `./scripts/test.sh` passes
- [ ] If the IPC protocol changed, I updated `packages/protocol`, the Rust side, the Dart side, and bumped the protocol version
- [ ] No model weights or build artifacts committed
