## Summary

Describe the focused change and why it is needed.

## Hypothesis and scope

- Hypothesis:
- Preload target or subsystem:
- Trigger:
- Release/cleanup point:
- Explicitly out of scope:

## Source contracts

List changed Darktide/DMF APIs or hooks and the source paths used to verify
their signatures, returns, lifecycle, and authority.

## Validation

- Static commands and results:
- Runtime context and result:
- Performance or memory comparison:
- Untested contexts:

## Release impact

- User-facing change:
- Version/changelog required:
- New runtime files or dependencies:

## Checklist

- [ ] Branch started from current `master`.
- [ ] Only intended Instantium files are changed.
- [ ] Runtime Lua and `.mod` files pass syntax and LuaLS validation.
- [ ] Hook/API contracts are source-verified where applicable.
- [ ] Disable, unload, transition, and failure cleanup are covered.
- [ ] Temporary probes, logs, captures, and local paths are absent.
- [ ] InstantHub was disabled during runtime tests.
- [ ] Runtime results and remaining gaps are reported accurately.
