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
look like every other Tor user. This is the right default for almost everyone.

> **`CORR_BRIDGES` is NOT implemented yet.** KratosOS does not provision Tor
> bridges into the Gateway, so setting `CORR_BRIDGES=obfs4|snowflake` makes
> Stealth Mode **refuse to start** (fail-closed) rather than imply your ISP
> can't see Tor. To use bridges today, set the bridge lines directly in the
> Whonix Gateway's `torrc` and leave `CORR_BRIDGES=off`.

### 2. Local-link shaping (opt-in, `CORR_LINK_SHAPING=on`, needs `vpn` mode)
`kratos corr shape on` installs, on your **you→VPN uplink only**:
- a **token-bucket rate limit** (`CORR_SHAPE_RATE`) that caps bursts to a ceiling
  (it limits, it does not by itself generate constant traffic);
- **netem jitter** (`CORR_SHAPE_JITTER`) so fine-grained timing is smeared;
- optional **decoy traffic** (`CORR_DECOY`, via `kratos-decoy`) to a sink inside
  the tunnel, filling the pipe with cover so volume is constant.

This blinds **your ISP / local network** to what you're doing inside the tunnel.
It does **not** defeat a global adversary, and it makes your uplink look
unusual, so it is off by default and `kratos fingerprint` flags it when on. Use
it only when a *local* observer is the specific worry (e.g. an untrusted
network) and you accept standing out to them.

### 3. Mixnet mode (`CORR_MODE=mixnet`) — the intended global-adversary answer, NOT YET WIRED IN
A **Loopix-style mixnet** ([Nym](https://nym.com/docs/network/mixnet-mode/loopix))
sends *constant* cover traffic and delays each message by an independent random
amount across multiple mix nodes, so an observer sees a steady, uninformative
stream whether or not you're doing anything — **unobservability**, not just
unlinkability, at seconds of latency. This is the design answer to a global
adversary.

> **NOT IMPLEMENTED: Stealth refuses to start with `CORR_MODE=mixnet`.**
> KratosOS does **not** install or route the persona through Nym, so rather than
> give a false sense of mixnet protection, Stealth Mode fails closed when
> `CORR_MODE=mixnet` is set. What exists today is experimental *components*, not
> an integrated path: `workstation/nym/` provides `kratos-nym` (writes a
> nym-socks5-client config with Loopix cover traffic forced ON) and `nym.nft`, a
> fail-closed workstation firewall that lets ONLY the `kratos-nym` user reach the
> network (unit-tested in `tests/nym_test.sh`). Turning this into a real,
> Stealth-provisioned path — installing `nym-socks5-client` into the persona,
> supervising it, health-checking it and pointing apps at it — is still to do.

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
- Global adversary: only a mixnet (Nym) genuinely helps, at a latency cost — and
  it is **not yet integrated** (Stealth refuses `CORR_MODE=mixnet`, see §3). If
  your life depends on beating a global adversary, assume low-latency anonymity
  is not enough and do not treat KratosOS as providing the mixnet today.

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

## The Stealth correlation profile (`CORR_STEALTH_PROFILE`)

Stealth Mode applies one profile automatically on start:

| Profile | What it does | Latency | Against a LOCAL observer (ISP) | Against a GLOBAL adversary |
|---|---|---|---|---|
| `off` **(default)** | Tor defaults only (connection padding + vanguards-lite, on inside the Whonix Gateway). Maximum blend-in. | lowest | volume/timing visible | not defeated |
| `balanced` | **Rate-limit** the host uplink (`CORR_SHAPE_RATE`) + add **jitter**. A decoy cover stream is added only if `CORR_DECOY_SINK` is set *and* network mode is `vpn`. | low, a little slower | bursts smoothed; idle-vs-active still visible without a decoy | not defeated |
| `max` | Same host shaping as `balanced`, and **warns** that the Nym mixnet is not active. It does **not** route through Nym. | low, a little slower | same as `balanced` | not defeated |

**Why `off` is the default:** it is the honest baseline. The `balanced`/`max`
shaping is a rate **limiter** plus jitter, not a traffic **generator**: with no
running decoy it smooths bursts and perturbs fine timing, but it does **not**
hide idle-vs-active periods, so calling it "constant-rate padding" would be a
lie. A constant-rate pipe only exists when you also run a decoy cover stream
(`CORR_DECOY` + `CORR_DECOY_SINK`) through the VPN tunnel. Shaping also makes
your uplink look *unusual* to the same local observer, so it is a deliberate
opt-in, not something we switch on for every user.

**The honest tradeoff (read this):** turning on `balanced` trades *blend-in* for
*partial volume/timing blinding* against a local observer, and only becomes true
constant-rate cover with a decoy running inside the tunnel. If your threat model
is "a local observer doing traffic analysis," enable it (and ideally a decoy);
if it is "don't be noticed using Tor at all," leave it `off` and use bridges.
Neither `balanced` nor `max` defeats a true global passive adversary on
low-latency Tor — **only the Nym mixnet (`CORR_MODE=mixnet`) does**, at seconds
of latency, and `max` does *not* enable it for you (KratosOS does not yet
provision `nym-client` into the persona). Tune the rate with `CORR_SHAPE_RATE`.

## How we compare to Vanguards and MUFFLER

Two defenses people ask about, and where KratosOS stands:

**Tor Vanguards (guard-discovery defense).** `vanguards-lite` — layer-2 guard
pinning, built into Tor 0.4.7+ — is **already active by default inside the
persona Whonix Gateway**, so our circuits already resist guard-discovery
attacks. This is a *different* threat from the volume/timing correlation the
Stealth padding profile addresses; the two are complementary. The **full
`vanguards` add-on** (adds layer-3 guards + rendguard/bandguards monitors) is
stronger but mainly benefits onion-*service* operators, and its extra hop costs
latency — so it is **opt-in, not default**, for a low-latency browsing persona.

The helper ships on the KratosOS host for reference at
`/usr/share/kratos/gateway/kratos-gw-harden`. Because KratosOS keeps **no
host→guest channel by design**, it is not present inside the Gateway — copy its
contents into the kx-gw Gateway (paste it into an editor there, or fetch it over
the persona's own network) and run it as root:

```
# inside the kx-gw Gateway, as root, after pasting the script in:
sudo bash kratos-gw-harden
```

It enables the full add-on and turns on maximum Tor connection padding
(`ConnectionPadding 1`, `ReducedConnectionPadding 0`), and prints honestly
whether the full add-on actually enabled (vanguards-lite is always on regardless).

**MUFFLER (2025).** MUFFLER obfuscates flow correlation at Tor's **final egress
hop** by shuffling/splitting N real connections onto M virtual connections
between the exit relay and the destination. It must be deployed at the **exit
side** — a client (all KratosOS controls) cannot deploy it unilaterally, so
there is nothing to "implement" here. Its goal — defeating end-to-end flow
correlation — is precisely what a **mixnet** provides end-to-end, which is the
`CORR_MODE=mixnet` (Nym) path. Note that `CORR_STEALTH_PROFILE=max` is NOT that
path — it is only host rate-limiting/jitter and explicitly does not route
through Nym. And `CORR_MODE=mixnet` itself is not wired in yet (Stealth refuses
it), so the mixnet property is the *intended* answer, not a shipped one. For a
client, a mixnet is the deployable route to that property; MUFFLER is not
deployable at all.

**So:** we already have the vanguards baseline (lite), offer the full add-on as
an opt-in, and the flow-correlation property MUFFLER targets would come from the
Nym mixnet rather than an exit-side scheme a client can't run — once Nym is
actually integrated. None of this changes the honest top-line: only a mixnet
gives a real story against a global passive adversary on anything resembling low
latency, and KratosOS does not provide that mixnet path today.
