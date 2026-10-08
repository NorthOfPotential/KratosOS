# KratosOS Security Toolset

KratosOS ships a curated, menu-organised security/pentest arsenal. Open the
application launcher and look under **KratosOS Security**; the tools are grouped
into submenus:

| Menu | What's in it |
|------|--------------|
| **Reconnaissance** | nmap, ncat, masscan, arp-scan, netdiscover, dig, dnsrecon, fierce, whois, theHarvester, whatweb, smbclient, snmpwalk |
| **Scanning & Vuln** | Nmap NSE vuln scripts, nikto, wapiti, lynis (audit *this* host), legion |
| **Web** | sqlmap, dirb, gobuster, feroxbuster, ffuf, wfuzz, OWASP ZAP, wpscan, skipfish, sslscan |
| **Wireless** | aircrack-ng, wifite, reaver, bully, mdk4, kismet, hcxdumptool |
| **Password Attacks** | john, hashcat, hydra, medusa, ncrack, crunch, cewl, hashID |
| **Sniffing & MITM** | Wireshark, tshark, tcpdump, ettercap, bettercap, dsniff, mitmproxy, ngrep |
| **Forensics** | Sleuth Kit, Autopsy, foremost, scalpel, testdisk/photorec, binwalk, ExifTool, steghide, YARA, ddrescue |
| **Reverse Engineering** | radare2, rizin, gdb, ltrace, strace, apktool, hexedit |
| **Exploitation** | searchsploit (Exploit-DB), SET, THC-IPv6, and a Metasploit install helper |
| **Anonymity** | proxychains, torsocks, macchanger |
| **Logging & Monitoring** | **Live System Log** (KratosOS), KSystemLog, htop, btop, iftop, nethogs, iotop, audit log |
| **Script Execution** | **Run Script (sandboxed)** (KratosOS), IPython, Python 3, Konsole |

## How the launchers behave

- **CLI tools** open a Konsole primed for that tool: it runs the command once
  (usually showing its help/usage) and then drops you to a shell so you can
  re-run it with your own arguments. Many tools need root — prefix with `sudo`.
- **GUI tools** (Wireshark, ZAP, Kismet, Autopsy, Ettercap, Legion) launch
  directly.

## KratosOS custom tools

- **Live System Log** (`kratos-logwatch`) — follows the system journal live.
- **Run Script (sandboxed)** (`kratos-runscript <script>`) — runs a `.sh`/`.py`
  script inside a Firejail sandbox (no network, private `/tmp`, read-only home),
  for safely trying untrusted scripts.
- **`kratos-sec install-metasploit`** — Metasploit isn't in Debian; this only
  PRINTS the official Rapid7 install instructions (release downloads or their
  APT repo) for you to review and run yourself. It deliberately does **not**
  download or execute Rapid7's installer for you.

## Not in Debian (install separately)

A few well-known tools aren't packaged by Debian and so aren't preinstalled:

- **Metasploit Framework** — `kratos-sec install-metasploit` prints the official Rapid7 instructions to follow yourself (it does not run an installer).
- **Burp Suite** — download from PortSwigger; OWASP **ZAP** is preinstalled as a free alternative.
- **Ghidra** — download from the NSA/ghidra releases; **radare2/rizin** are preinstalled.
- **SecLists / wordlists** — clone `danielmiessler/SecLists`; `crunch` and `cewl` are preinstalled for generating your own.

The build installs tools **tolerantly**: if Debian renames or drops a package,
it's skipped and no dead menu entry is created. The catalog lives at
`/usr/share/kratos-assets/sectools.tsv` — add a row and rerun
`/usr/local/lib/kratos/sectools-gen --check-binaries` to extend the menu.

## Responsible use

These are dual-use tools. Use them **only** against systems you own or are
explicitly authorised to test (your own lab, a CTF, a signed engagement).
Scanning, cracking, sniffing, or exploiting systems without permission is
illegal in most jurisdictions. KratosOS gives you the tools; the authorisation
is on you.
