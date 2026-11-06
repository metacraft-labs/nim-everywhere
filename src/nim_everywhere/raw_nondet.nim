## Marks the platform implementation boundary without depending on consumers.
## Strict builds reject the legacy raw entry points. Backend implementations
## explicitly request RawBackendAccess to delegate without re-entering hooks.
## This is a reviewable escape hatch, not a security capability: source lint
## remains necessary, especially for effects deferred through closure fields.
type
  RawNondet* = object of RootEffect
  RawBackendAccess* = object

const rawBackendAccess* = RawBackendAccess()
