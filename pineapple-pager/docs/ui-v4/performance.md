# DEFCON Defense Pager Performance Verification

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

### v4.19 host build gate

Before touching either Pager, the same source was compiled before and after the
resource pass with Go 1.26.1. The memory figures below are three-run medians from
the macOS host while rendering all 17 preview screens with the Pager's real
Material Icons file supplied to both builds; they are a comparative build gate,
not a substitute for device measurements.

| Metric | v4.18 baseline | v4.19 candidate | Change |
|---|---:|---:|---:|
| MIPS32 binary | 7,340,225 B | 7,012,545 B | -327,680 B (-4.5%) |
| Maximum resident set | 18,923,520 B | 16,711,680 B | -2,211,840 B (-11.7%) |
| Peak memory footprint | 11,600,448 B | 9,765,392 B | -1,835,056 B (-15.8%) |
| Vendored Go source | 1,497,770 B | 686,569 B | -811,201 B (-54.2%) |

## Optimizations

- The native renderer starts before the monitoring libraries load, so the
  designed General screen owns the physical display while Recon and evidence
  workers initialize behind it.
- The launch-confirm input is allowed to finish before evdev navigation arms,
  preventing a fresh session from opening Threat Details accidentally.
- Framebuffer writes occur only when rendered pixels change.
- The renderer reuses one canvas plus two RGB565 buffers instead of allocating
  and retaining redundant full-screen pixel copies.
- Ten fixed UI icons use the already-linked bitmap face, so the binary no longer
  links or initializes the OpenType/SFNT/vector stack.
- Button navigation renders from cached live state instead of rereading every
  state file first.
- Idle state uses inexpensive file fingerprints; parsing and rendering happen
  only after a state change, minute change, capture timer, or toast transition.
- PNG publication uses the lowest-CPU encoder and runs only for a changed frame.
- Virtual Pager uses per-run ETag revisions and change-driven long polling.
  Version 4.19 holds an unchanged frame for five seconds and bounds the browser
  request at 6.5 seconds. This cuts idle request churn by about 85% compared
  with the former 750 ms hold while changed frames still wake immediately.
- The browser admits one button until the screen advances or a short safety
  timeout expires. The Go queue holds only one unhandled press.
- Page show, network return, and tab visibility all reset the bridge cleanly.
- While the app owns the screen, the exact Pager UI is shown without the stock
  login, loading, terminal, or payload-portal layers competing for attention.
- A device-side lock prevents duplicate UI/background/bridge processes.
- Framebuffer ownership reads stop after the eight-second launch handoff rather
  than running 20 times per second for the life of the session.
- Physical input uses a bounded kernel wait and refreshes its evdev descriptor
  every ten minutes, so cancellation, disconnect, and driver recovery cannot
  leave the only reader blocked indefinitely.
- PineAP Recon calls have an eight-second watchdog. Concurrent monitor/action
  workers use separate atomic state files, and the status badge exposes
  DEGRADED or STALE data instead of silently freezing the last good snapshot.
- Watched/trusted/baseline classification is one `awk` pass per Recon snapshot
  instead of several processes per AP. Band, threat, and watched counts also
  share one metrics pass.
- Existing PCAP discovery compares the directory and index in one linear pass,
  runs once per UI session, and checks capture growth without rescanning every
  saved PCAP each second.
- The portal loads the bridge from a versioned external script tag rather than
  embedding and reprocessing the full bridge source in `index.html`.
- The screen/button server binds only to the USB-management address and rejects
  requests without the persistent random token injected into Virtual Pager.
- The screen endpoint admits at most four clients and has header, write, idle,
  and request-size limits so abandoned browser requests cannot accumulate.
- Published screen buffers are immutable and shared by in-flight responses,
  eliminating the former 320 KB allocation and copy on every changed-frame
  download.

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
