# DEFCON Defense Pager v4.9 Performance Verification

Measured on the connected WiFi Pineapple Pager with the authenticated Virtual
Pager open and DEFCON Defense launched from **Payloads > General**.

## Results

| Metric | Before | v4.9 | Result |
|---|---:|---:|---:|
| Idle `defcon-ui` CPU | 39.70% over 10 s | about 2% over 10 s | about 95% lower |
| UI resident memory | 12,988 KB | 11,760 KB | lower and stable |
| UI threads | not recorded | 7 | stable |
| Unchanged screen transfer | 480,420 bytes across 30 requests | 0 image bytes on a held idle request | eliminated |
| Page refresh recovery | stock login/loading and a failed-data toast still visible after 15.5 s | designed General screen restored in 1.223 s total | no stock loading detour |
| Local health request | not recorded | 200 in 0.039 s | healthy |
| Current-screen request | not recorded | 200, 320,103 bytes in 0.155 s | healthy |
| Active UI instances | unguarded | exactly one | duplicate-safe |
| `WAIT_FOR_INPUT` workers | could accumulate | 0 | eliminated |

CPU is calculated from `/proc/<pid>/stat` user and system ticks with a 100 Hz
clock. The v4.9 sample includes an open Virtual Pager tab and normal monitoring
activity.

## Optimizations

- The native renderer starts before the monitoring libraries load, so the
  designed General screen owns the physical display while Recon and evidence
  workers initialize behind it.
- The launch-confirm input is allowed to finish before evdev navigation arms,
  preventing a fresh session from opening Threat Details accidentally.
- Framebuffer writes occur only when rendered pixels change.
- Button navigation renders from cached live state instead of rereading every
  state file first.
- Idle state uses inexpensive file fingerprints; parsing and rendering happen
  only after a state change, minute change, capture timer, or toast transition.
- PNG publication uses the lowest-CPU encoder and runs only for a changed frame.
- Virtual Pager uses ETag revisions and change-driven long polling. A 6.5 s
  browser timeout resets a request that outlives the server's 5 s hold.
- The browser admits one button until the screen advances or a short safety
  timeout expires. The Go queue holds only one unhandled press.
- Page show, network return, and tab visibility all reset the bridge cleanly.
- While the app owns the screen, the exact Pager UI is shown without the stock
  login, loading, terminal, or payload-portal layers competing for attention.
- A device-side lock prevents duplicate UI/background/bridge processes.

## Verification

- The complete Pager shell suite, Go tests, race tests, vet, package manifest,
  JavaScript syntax check, and macOS-metadata exclusion all passed.
- The final MIPS32 binary was checksum-verified before installation.
- General, threat, evidence, evidence detail, Back navigation, physical input,
  keyboard mappings, rapid double-press suppression, browser refresh, clean
  exit, and a real-menu cold launch were exercised on the connected Pager.
- The final canvas remains visually aligned with the equal-size reference
  comparisons under `docs/ui-v4/qa/`.
- Passive monitoring and bounded PCAP safeguards are unchanged.
