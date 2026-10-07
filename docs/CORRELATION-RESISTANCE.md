# Traffic-Correlation Resistance

## The hard truth first

A **global passive adversary** — one who can watch traffic *entering* the
anonymity network near you and *leaving* it near your destination — can
correlate the two ends by timing and volume, **without breaking any
encryption**. This is a known, unsolved limitation of all low-latency networks,
Tor included. Academic surveys are blunt about it: mitigating end-to-end
confirmation against a global adversary is an open research problem
([MIT survey](https://css.csail.mit.edu/6.858/2023/readings/tor-traffic-analysis.pdf),
[Website-Fingerprinting survey, 2025](https://arxiv.org/pdf/2510.11804)).

So: **no setting in KratosOS makes you safe against an adversary who sees both
ends.** What follows raises cost against *weaker* observers and, with a mixnet,
gives a real story against a global one — at a steep usability price.

## The fingerprint trap (why most "fixes" backfire)

The instinct is to add padding, jitter and decoy traffic. The catch: if *you*
add an unusual pattern that ordinary Tor/VPN users don't, you no longer blend
in — **your countermeasure becomes your fingerprint.** Anonymity is a crowd;
standing out defeats it.

KratosOS therefore makes the aggressive options **opt-in and off by default**,
and keeps the default posture "look exactly like a normal Tor/Whonix user."
`tests/test_fingerprint.py` enforces that the shipped defaults blend in, and
`kratos fingerprint` checks a running machine for things that make it stand out.

## What KratosOS offers, weakest-adversary to strongest

### 1. Blend with the Tor crowd (default, `CORR_MODE=tor`)
Use Tor exactly as Tor Browser + Whonix do: connection padding, standard
circuits, default window sizes. Your protection is the **anonymity set** — you
look like every other Tor user. Add bridges (`CORR_BRIDGES=obfs4|snowflake`) so
your ISP can't even tell you use Tor. This is the right default for almost
everyone.

### 2. Local-link shaping (opt-in, `CORR_LINK_SHAPING=on`, needs `vpn` mode)
`kratos corr shape on` installs, on your **you→VPN uplink only**:
- a **token-bucket rate limit** (`CORR_SHAPE_RATE`) so bursts become a flat rate;
- **netem jitter** (`CORR_SHAPE_JITTER`) so fine-grained timing is smeared;
- optional **decoy traffic** (`CORR_DECOY`, via `kratos-decoy`) to a sink inside
  the tunnel, filling the pipe with cover so volume is constant.

This blinds **your ISP / local network** to what you're doing inside the tunnel.
It does **not** defeat a global adversary, and it makes your uplink look
unusual, so it is off by default and `kratos fingerprint` flags it when on. Use
it only when a *local* observer is the specific worry (e.g. an untrusted
network) and you accept standing out to them.

### 3. Mixnet mode (opt-in, `CORR_MODE=mixnet`, experimental)
The only option here with a real answer to a global adversary. A **Loopix-style
mixnet** ([Nym](https://nym.com/docs/network/mixnet-mode/loopix)) sends
*constant* cover traffic and delays each message by an independent random amount
across multiple mix nodes, so an observer sees a steady, uninformative stream
whether or not you're doing anything — **unobservability**, not just
unlinkability. The cost is high latency (seconds), so it suits messaging, not
browsing. In KratosOS this routes the persona through Nym instead of (or in
front of) Tor.

> **Status: integration shipped, live path untested here.** `workstation/nym/`
> provides `kratos-nym` (writes a nym-socks5-client config with Loopix cover
> traffic forced ON) and `nym.nft`, a fail-closed workstation firewall that
> lets ONLY the `kratos-nym` user reach the network — so apps either go through
> the mixnet or nowhere (tested in `tests/nym_test.sh`). It still needs the
> real `nym-socks5-client` binary and a reachable Nym gateway, which this
> project has not run end-to-end. Install it inside the persona workstation
> (see that folder's header and docs/QUBES.md).

### 4. Layering (you → VPN → Tor, and beyond)
KratosOS already supports **you → VPN (host, `mode vpn`) → Tor (Gateway)**: your
ISP sees only the VPN; the VPN sees only Tor; the destination sees a Tor exit.
You can add further layers *inside the Workstation* (e.g. a second,
independently-paid VPN inside Tor) so an adversary must compromise more
independent operators. Diminishing returns apply, and more layers = more
latency and a smaller crowd, so weigh each one. Pay for any VPN anonymously or
don't use it.

## Behaviour that pierces every defense
Padding can't hide a pattern you keep making:
- **Don't do predictable high-bandwidth things** (large streams, synced
  torrents) over the anonymity layer — their volume fingerprint punches straight
  through cover traffic. KratosOS can't stop this; only you can.
- Vary *when* you're active (see the timing guard, `GUARD_START_JITTER`, and
  OPSEC.md). Regular hours are a location/timezone tell.
- Keep sessions short and purpose-scoped.

## Bottom line
- Default: blend with Tor. Best anonymity-set, no fingerprint. Right for most.
- Local worry: add link shaping, knowing it's local-only and makes you stand out.
- Global adversary: only a mixnet (Nym) genuinely helps, at a latency cost, and
  it's still experimental here. If your life depends on beating a global
  adversary, assume low-latency anonymity is not enough.

## Sources
- [Traffic Analysis Attacks on Tor: A Survey (MIT)](https://css.csail.mit.edu/6.858/2023/readings/tor-traffic-analysis.pdf)
- [Website Fingerprinting Attacks and Defenses, survey (arXiv, 2025)](https://arxiv.org/pdf/2510.11804)
- [Nym / Loopix mixnet mode](https://nym.com/docs/network/mixnet-mode/loopix)
- [Nym (mixnet) overview](https://en.wikipedia.org/wiki/Nym_(mixnet))

## Nym: the trust boundary is the dedicated UID (honest note)

The Nym fail-closed firewall (`workstation/nym/nym.nft`) permits network egress
only from the `kratos-nym` user. That means its real security boundary is
"any process running as `kratos-nym`" — a compromised program under that UID
could open arbitrary direct connections and bypass the SOCKS/mixnet path. So
`kratos-nym` is a locked, dedicated service account that runs nothing but the
Nym client, and the systemd unit should be sandboxed (no new privileges, private
tmp/dev, minimal filesystem). Don't run anything else under it.
