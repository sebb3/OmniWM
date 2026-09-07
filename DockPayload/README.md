# OmniWM Dock payload

This directory is OmniWM's maintained copy of the privileged Dock payload and
its protocol. OmniWM needs to build and evolve it together with the workspace
transition client; it must not depend on a sibling Hammerspoon 2 checkout.

The initial source was imported from `sebb3/Hammerspoon2` commit `6badeea`
(`fleet/dock-workspace-transition`). It retains the `hs2_dock_*` names and v2
socket contract for a reviewable, behavior-preserving import. Those are source
identifiers, not an external runtime dependency.

The copy includes:

- the complete C protocol and lease/session server;
- the Dock payload lifecycle and operation dispatcher;
- the bounded multi-window workspace transition primitive;
- the C status client and all self-contained C tests.

The Hammerspoon-specific Swift client test and historical spike evidence were
not imported. OmniWM's Swift client and integration will be implemented against
this copy.

## Verification

```sh
make -C DockPayload all test sanitize analyze
```

These checks build universal arm64/arm64e payload slices and exercise the
protocol, socket, lifecycle, peer-loss, operation, and workspace-transition
tests without loading anything into Dock.
