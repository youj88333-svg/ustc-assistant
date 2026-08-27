# Security patches

This package is a project-local security fork of
[`webview_flutter_windows` 1.1.1](https://github.com/omar-hanafy/webview_flutter_windows).
The exact upstream baseline is tag `webview_flutter_windows-v1.1.1`, commit
`5af5ff15b1fe8bc44e82c50fac2e62efb1d14b1e`. The upstream BSD-3-Clause
license remains in `LICENSE`.

No upstream cookie, storage, request-header, or response-body getter is part
of the USTC browser port. The application imports this fork only through the
restricted platform adapter described by D-22/D-23/D-24/D-25/D-26/D-29/D-30.

| Patch | Contract | Native files | Test |
|---|---|---|---|
| Synchronous structured top-level navigation allowlist | 07 redline 2.1-3; 09 CT-C0-05; D-23 | `navigation_policy.*`, `webview.*`, `webview_bridge.*` | `navigation_policy_test.cc`; M2 feasibility navigation escape case |
| Debug-only exact `127.0.0.1:<port>` fixture route | process redline 2.3-1; R-01 | `navigation_policy.*`, plugin CMake | Debug/Release native policy tests; M2 feasibility test |
| Unconditional download, popup, and permission denial | ADR-019; D-22/D-23 | `secure_event_policy.h`, `webview.*` | `secure_event_policy_test.cc`; M2 feasibility popup/download/permission cases |
| Clear all WebView2 profile browsing data | ADR-019; CT-P-05; D-22 | `webview.*`, `webview_bridge.*` | M2 feasibility clear/delete case |
| Awaited controller disposal and environment release signal | ADR-002/019; D-22/D-26 | `environment_lifecycle.*`, `webview_windows_plugin.cc` | `environment_lifecycle_test.cc`; M2 feasibility two-UDF case |
| Native-only trusted session snapshot, DPAPI protected and atomically replaced | ADR-002/019; D-22 | `session_snapshot.*`, `webview.*`, `webview_bridge.*` | `session_snapshot_test.cc`; cold-start M2 acceptance |

Local methods are deliberately narrow:

```text
setNavigationPolicy(allowedOrigins, allowedPathPrefixes, debugLoopbackPort?)
denyDownloads()
denyNewWindows()
denyPermissions()
clearBrowsingDataAll()
restoreTrustedSessionSnapshot(P-owned path)
persistTrustedSessionSnapshot(P-owned path)
disposeControllerAndAwaitRelease()
awaitEnvironmentReleased()
```

The snapshot methods never return cookie names, values, domains, or metadata
to Dart. Native code admits only session cookies for the four compiled USTC
authentication hosts, encrypts the complete binary envelope with current-user
Windows DPAPI, zeroes plaintext buffers, and replaces the per-account snapshot
atomically. A missing snapshot is a normal first-run state; a corrupt or
undecryptable snapshot fails closed.

Production uses a compile-time allowlist. Runtime policy injection is accepted
only by a Debug plugin build and only for the exact IPv4 loopback address and
port supplied by the synthetic fixture server. Release/Profile builds reject
that field.
