# Network Diagnostics Toolkit

Reusable troubleshooting kit for "internet feels slow" — works at home, at a cafe,
at a new location, anywhere on Windows.

**Location:** `D:\Vibe code\Network Diagnose`

## How to run

**Easiest way:** just double-click `Run Diagnostics.bat` in this folder. It opens a
PowerShell window, runs the full sweep, and leaves the window open so you can read
the results and see where the report was saved.

**Or from a terminal** (quotes needed because of the space in the folder name):

```
powershell -ExecutionPolicy Bypass -File "D:\Vibe code\Network Diagnose\scripts\diagnose.ps1"
```

Or `cd` into the folder first, then use the relative path:
```
cd "D:\Vibe code\Network Diagnose"
powershell -ExecutionPolicy Bypass -File scripts\diagnose.ps1
```

Optional parameters:
```
powershell -ExecutionPolicy Bypass -File "D:\Vibe code\Network Diagnose\scripts\diagnose.ps1" -TargetHost "8.8.8.8" -ThroughputUrl "https://proof.ovh.net/files/10Mb.dat" -WifiAdapterName "Wi-Fi" -DnsTestHost "google.com"
```

Two extra checks are off by default because they're slower or call an external
service — add the switch to turn them on:
```
powershell -ExecutionPolicy Bypass -File "D:\Vibe code\Network Diagnose\scripts\diagnose.ps1" -CheckMtu -CheckAsn
```
- `-CheckMtu` auto-discovers the largest packet that gets through unfragmented to
  your target, and reports the functional MTU (useful for configuring a VPN).
- `-CheckAsn` tags every public traceroute hop with its ISP/ASN (via ip-api.com,
  e.g. `AS45899 - VNPT`), so you can see whether a slow hop is on your home ISP
  or a distant transit network. Needs internet access to ip-api.com; fails
  silently (with a note in the report) if that's unreachable.

It checks, in order:
1. Gateway latency/loss/jitter (local Wi-Fi/LAN health)
2. Captive portal check — detects a login page (hotel/cafe/office Wi-Fi)
   intercepting your traffic before anything else is even worth testing
3. Wi-Fi signal, RSSI, and radio type (flags weak signal and explains the
   real-world speed ceiling of your Wi-Fi generation, e.g. Wi-Fi 4 ≈ ~150 Mbps
   max regardless of ISP plan)
4. DNS resolution speed — queries a real hostname twice: once uncached (hits
   your resolver) and once cached (hits local cache), so you can see the actual
   upstream cost
5. Latency, jitter (standard deviation, not just min/max), and loss to an
   internet target — high jitter is flagged separately since it causes VoIP/
   gaming stutter even when average ping looks fine
6. Traceroute (finds the specific bad hop, e.g. ISP backbone congestion),
   optionally ASN-tagged with `-CheckAsn`
7. IPv4 vs IPv6 (catches PMTU black holes — handshake fast, data crawls).
   Reports one of three states: **Healthy** (within 20% of IPv4), **Degraded**,
   **Blackhole/Slow** (>2x slower — a classic cause of browsers hanging), or
   **Unavailable** (no IPv6 response at all)
8. **Single-stream vs 4-parallel-stream throughput** — the key test that reveals
   per-connection ISP throttling (speedtest looks great, real browsing doesn't)
9. Proxy/VPN/security software sanity check
10. Path MTU discovery (only with `-CheckMtu`)
11. **Plain-Language Summary & Diagnosis** — every section above feeds a verdict
    (OK / MINOR / PROBLEM / LIKELY ISP THROTTLING) that gets collected into a final
    summary at the end of the report, so you don't have to interpret the raw numbers
    yourself. It's grouped into "Problems to act on", "Notes / minor items", and
    "Passed checks". The console window also prints a one-line headline
    (issues found vs. all clear) when the run finishes.
12. **Change Since Last Run** — key metrics (gateway ping, DNS time, jitter,
    throttling ratio, etc.) are saved to `reports\baseline.json` after every run
    and diffed against the previous run, so you get lines like
    "DNS is 40ms slower than last run" when something degrades over time.

A timestamped report is saved to `reports\diagnostic_YYYY-MM-DD_HHMM.txt`.

## Interpreting the throughput test (step 7)
- **Scaling factor near 4x** (e.g. 1 stream = 15 Mbps, 4 streams = 60 Mbps) →
  your ISP is throttling per-connection/per-flow. This is why speedtest (many
  parallel streams) looks fast but normal browsing (few streams per site) feels slow.
  Call the ISP with `templates/isp_evidence_template.md` filled in from the report.
- **Scaling factor near 1x** (4 streams ≈ same total as 1 stream) → you're hitting
  a real bandwidth ceiling, not per-connection throttling. The fix is a plan upgrade,
  not a support ticket about throttling.

## If IPv6 numbers in step 6 are much worse than IPv4
Disable IPv6 on the adapter (reversible):
```
Disable-NetAdapterBinding -Name "Wi-Fi" -ComponentID ms_tcpip6
```
Re-enable anytime with:
```
Enable-NetAdapterBinding -Name "Wi-Fi" -ComponentID ms_tcpip6
```

## Preparing ISP evidence
Copy `templates/isp_evidence_template.md`, fill in the bracketed values from your
latest report in `reports/`, and use it as your call script / evidence to send.

## Known-good baseline (for comparison across locations/times)
Record your own baseline here after a first clean run, e.g.:
- Location: Home (Hanoi) — Gateway ping: ~2ms — DNS: Cloudflare 1.1.1.1 —
  Single-stream: ~15-20 Mbps — 4-stream: ~70 Mbps — Speedtest: ~179 Mbps —
  Known issue: per-connection throttling suspected, IPv6 PMTU black hole (fixed
  by disabling IPv6 on Wi-Fi adapter).
