# OpSec Guide

Most real-world deanonymization comes from people's mistakes, not from broken
anonymity software. KratosOS can stop technical leaks. These rules cover the rest.

## Identity separation
- **Never** log into an account tied to your real identity in an anonymous session.
- One identity per session. Reboot (amnesia) between identities. Don't just switch tabs.
- Don't reuse usernames, passwords, email addresses, avatars or PGP keys across identities.
- Run `kratos newnym` when you switch tasks within the same identity.

## Behaviour
- Your writing style is a fingerprint (stylometry). Keep anonymous writing short and plain, and consider rewording it.
- Watch for time-zone patterns: when you're active reveals where you live. KratosOS sets the clock to UTC, but your schedule still shows.
- Don't mention local details (weather, events, prices, slang).
- Don't maximize the Tor Browser window. Its default size is part of its anti-fingerprinting design.

## Files
- Run `kratos scrub` on every file before sharing it. Photos contain GPS, camera serial numbers and timestamps.
- Open untrusted documents in `kratos vm`, not on the host.
- Office documents and PDFs can phone home when opened. Open them offline or in a VM.

## Network
- Prefer `tor` mode. Use `vpn-tor` if Tor is blocked or attracts attention where you are. Use `vpn` only when you trust the provider more than you need anonymity.
- Public Wi-Fi + KratosOS is better than home Wi-Fi + KratosOS, but cameras exist.
- Pay for VPNs anonymously (cash, Monero) or don't use them.

## Hardware & physical
- Use a dedicated device if you can. Leave your phone at home or powered off when it matters.
- `kratos panic` cuts the network and powers off. Remember the shortcut.
- Use a strong passphrase for persistence (6+ diceware words).

## Run `kratos check` at the start of every session.
