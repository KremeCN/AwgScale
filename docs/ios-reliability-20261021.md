# iOS reliability review — 2026-10-21

## Reference boundary

The supplied `Tailscale.ipa` identifies itself as Tailscale iOS 1.104.1
(build 101.104.1). Its SHA256 is
`1fcd5a68ed497ee6e29c377e2235faeb432064c0c94f6cff9719a9976845f837`.
The recovered IPNExtension bytes match the member in that archive (SHA256
`7cb1ade3e17f8229d48609807b8f7529424d5f034396fdbdafc1a1e170ab36e1`).

A fresh REA `inspect_macho` inspection confirms `cryptid=1`, encrypted file
range `[16384, 17235968)`, with the entrypoint at offset `8837348` inside it.
Evidence: `ev_11f89a58655e854b8e2580f46e89126472a3854ab81ad6838569b6dce9a0fa30`.
The recovery directory contains metadata, symbols and build information, not
recovered Swift or Go function bodies. It cannot establish official behavior
or source parity. No encrypted-code pseudocode was used as an implementation.

| Observable official interface name | AwgScale comparison area | Evidence boundary |
| --- | --- | --- |
| `goRunBackend`, `goStopTunnel` | GoBridge, AppLoginBackend, backend publication and stop | Interface names only; fixes below come from AwgScale source and regressions |
| `goRegisterPrefsLoad`, `goRegisterPrefsSave` | GoAppContext and Keychain preferences | No official persistence algorithm recovered |
| `goSetupNotify` | Notification subscription and stale callback ownership | No official notification lifecycle recovered |
| `goNetworkUpdate`, `getDNSConfigAll`, `getMTU` | Existing path monitoring and tunnel configuration | No claim of identical DNS, MTU or reconnection policy |

## Confirmed problems and changes

1. **Backend readiness and requests.** The previous Start goroutine could
   publish ready before the LocalAPI handler existed. The caller's deadline
   also began only after waiting for ready. Start, handler initialization and
   publication now precede readiness, with synchronized access. Failed Start
   returns an error instead of panicking. Stop rejects late publication and
   cancels active requests. Request bodies and contexts remain alive through
   handler completion, rather than being closed as soon as response headers
   become available.
2. **Login backend ownership.** Concurrent starts share initialization. A
   stopped attempt's delayed success, failure or notification cannot subscribe
   to, stop, or update the next Swift backend generation.
3. **Teardown before restart or deletion.** Only disconnected/invalid counts
   as stopped. Timeout or cancellation prevents restart and state deletion.
   Logout holds the existing transition gate until completion, preventing a
   new login or connection from racing state cleanup. Existing login attempts
   remain cancellable. Stop failure preserves the existing local session.
4. **Late tunnel-settings completion.** A success callback after stopping
   cannot republish a default route. The stopping branch invokes the start
   completion off the settings queue, avoiding a synchronous queue self-wait.
5. **Credential durability.** Keychain writes update in place and only insert
   missing items. A failed replacement leaves the old key intact. Concurrent
   insertion is resolved in the same group. Temporary Keychain failures are
   propagated, not treated as absent login state or silently replaced with a
   stale/plaintext fallback. Existing entitlement-free fallback behavior and
   identifiers are preserved.

6. **Share Sheet cancellation and teardown.** The REA report's Share Extension
   inventory prompted a check of this separate entry point. Its old five-second
   stop loop silently returned on timeout, and readiness polling swallowed
   cancellation. It now reuses the tested VPN stop helper, propagates cancelled
   waits and checks cancellation before starting or restarting backend work.

## Additional REA report assessment

`REA-REPORT.md` dated 2026-10-21 confirms the same IPA digest and encrypted-code
boundary. It adds App Intents, WidgetKit, File Provider and Share Extension
metadata. These are feature-discovery leads, not evidence of implementation
algorithms or demonstrated reliability gains. The current release addresses the
confirmed Share Sheet wait issue; Siri shortcuts, widgets and Files integration
remain separate feature work. App Group and Keychain identifiers in the signed
AwgScale app and its two extensions agree. No reset-keychain switch is added:
that destructive action is not a recovery policy established by this report.

The core is pinned to fork 1.104.2 (`d7efe75c7cce10651036bda98145e550ce0986ff`),
WireGuard v0.0.34 (`63cef16b88aab8b23b843beac7ac6f553b7c5fd6`),
QUIC `10dfe69b6d4ca273c4284ec48d786206af62286e`, and
uTLS `7effde6a93dc68c3535eaa590b6d28c503e18ff6`. Builds use Go 1.27.3 and
published modules with `GOWORK=off`.

## Validation

- Two LocalAPI regressions first failed on the old implementation: startup
  wait exceeded the requested deadline; response delivery prematurely
  cancelled the request and closed its body.
- Keychain fault injection reproduced lost old values, hidden write errors,
  mistaken missing state and stale fallback reads. The extracted baseline
  failed; all eight fixed storage tests pass without accessing real keys.
- `go test -race ./libtailscale/...` and `go vet ./libtailscale/...` pass with
  the final 1.104.2 pins. Tests include publication/Stop races, late packet
  callbacks, request cancellation, empty responses and startup-error cleanup.
- Xcode Simulator suite: **121 passed, 0 failed, 0 skipped**, iOS 27.0,
  isolated iPhone 17 Pro simulator. Includes controlled delayed-start,
  logout ownership, cancellation and tunnel-stop regressions.
- Real-device and simulator arm64 Go framework slices build successfully.
  Local evidence and the device IPA build record are retained outside the
  repository under the sibling `evidence/` and `artifacts/` directories.

## Remaining acceptance boundaries

This release remains an experimental TrollStore-oriented preview, not proof
that all app functions match the official private client. Simulator tests do not exercise a physical
iOS Network Extension, device lock/unlock Keychain policy, background
suspension, Wi-Fi/cellular handoff, carrier networks or public-WAN throughput.

Go's underlying Start has no context argument. Stop can reject and clean up a
late initialization, but this change does not claim synchronous cancellation
of that underlying Start across process/instance boundaries. Likewise, system
callbacks across reuse of one PacketTunnelProvider object need device evidence;
this patch prevents publication after stopping, not a wholesale redesign of
all provider callback generations. Those cases remain explicit device test
items. The release uses the existing prerelease channel. No production-device
installation is performed as part of publication.
