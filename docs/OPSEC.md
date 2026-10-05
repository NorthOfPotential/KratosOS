# OpSec Guide: Running a Separate Persona

KratosOS gives you a sealed room. These rules keep you from carrying things in
and out of it. **Most people who get identified are identified by their own
behaviour, not by broken software.**

## The core rule

> The persona belongs to the Stealth Workstation, not to the computer.
> It is never used from anywhere else, and nothing flows between the two.

## Accounts & identity
- Create the persona's accounts **from inside the Workstation**, never from the normal desktop.
- New username, email, password and avatar. **Never reuse anything** from your real identity.
- Store the persona's passwords **inside the Workstation** (KeePassXC there), never in your normal password manager.
- **No phone numbers tied to you.** SMS verification is one of the most common ways accounts get linked to a real person. If a service insists, choose another service.
- Recovery emails and recovery questions must not point back to you.
- Don't pay for anything from the persona with a payment method in your name.

## Writing & language
- Your writing style is a fingerprint. Using a different language helps, but it isn't a guarantee.
- **Translate inside the Workstation**, logged out. If you paste persona text into DeepL, Google Translate or an AI assistant from your normal desktop, your personal account now stores the persona's words.
- The same goes for grammar checkers, AI tools and anything else that "helps" with text.
- Don't mention local details (weather, events, prices, local slang).

## Timing
- If the persona is only active exactly when you are online, the two can be correlated. Vary your sessions.
- Don't switch between your personal accounts and the persona in quick succession.

## Data crossing the boundary
- Clipboard and file sharing are technically disabled. **Don't work around them** by retyping persona data on the host or photographing the screen.
- Don't bring personal files into the Workstation. If you must, run `kratos scrub` on them first.
- Nothing from the persona goes back to the normal desktop.
- Open untrusted files only inside the Workstation, ideally with `STEALTH_WORKSTATION=disposable`.

## Browser in the Workstation
- Use Tor Browser. Consider the "Safer" or "Safest" security level.
- Don't maximize the window (its default size is part of the anti-fingerprinting design).
- Don't install extensions.
- Whonix provides **kloak**, which disguises your typing rhythm. Check that it is installed and running in your Workstation (see the Whonix wiki: "Keystroke Deanonymization").

## Backups
- Back up the vault file (`/var/lib/kratos/stealth.vault`) **separately** from your personal backups. If they sit on the same drive, finding one means finding both.

## Physical
- Stealth Mode blocks sleep. Turn Stealth Mode off when you leave.
- **Panic button:** tray → PANIC. It kills the VMs, locks the vault, cuts the network and powers off.
- Leave your phone elsewhere (or off) during persona sessions if location matters.

## Session checklist
1. Network mode as intended (`vpn` if you use VPN-before-Tor)
2. Stealth Mode on → check that the tray shows **STEALTH ON**
3. In the Workstation: Whonix's systemcheck says Tor is connected
4. Do the work. Nothing personal.
5. Stealth Mode off → check the tray shows **Normal**
