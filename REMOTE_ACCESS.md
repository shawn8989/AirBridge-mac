# Wield Host 1.1 development candidate

Pair with the iPhone `codex/remote-access-files` branch. The setup instructions,
security boundaries, and pending device acceptance checklist are maintained in
[AirPad/docs/REMOTE_ACCESS.md](https://github.com/shawn8989/AirPad/blob/codex/remote-access-files/docs/REMOTE_ACCESS.md).

New controls in the Host are **Keep available while plugged in** and **Shared
folders**. The existing Show Pairing QR action now creates a single-use version 2
code for independent secure pairing. Existing local pairings remain usable.
Do not reset the macOS permission database to troubleshoot capture: verify the
signed app path, rule out duplicate copies, and inspect the actual capture error.

The Host still listens on legacy TCP 52417 for older local phones. Independently
authenticated TLS control uses 52418; Files uses a separate TLS connection on
52419. Expanded features never use the legacy app-wide transport key. Keep
Tailscale running separately; Wield does not install a VPN or open router ports.

CI compiles the universal app and tests real TLS sockets, safe folder traversal,
atomic transfers, and the real file client/server including permission revocation.
The workflow's unsigned app artifact must be Developer ID signed and notarized
before distributing a candidate to the mini. Do not publish a GitHub release or
change the website download until device and TestFlight acceptance pass.

Real permissions, display capture, Spaces, physical input, power management,
cellular routing, and cross-version hardware compatibility remain unverified on
this candidate. The owner will test them later.
