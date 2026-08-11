# DEFCON Defense v4.9 Navigation and Refresh Audit

This audit used the connected WiFi Pineapple Pager, its six physical controls,
and the authenticated Virtual Pager. The approved 480 x 222 layouts remain the
visual source of truth; this pass changes launch, input, and browser ownership
rather than redesigning the screens.

## Reproduced issues

1. A Virtual Pager press could be accepted again before the prior frame reached
   the browser, allowing repeated input to skip or reverse a screen.
2. A pending long-poll request had no browser timeout, so a reboot or network
   interruption could leave the screen apparently stuck.
3. Refresh exposed the stock login/loading view, then partially loaded icon text
   and an installed-payload fetch error before returning to DEFCON Defense.
4. The launch-confirm A event could reach the new evdev reader and open Threat
   Details instead of the General screen.
5. Monitoring-library initialization ran before the custom renderer, extending
   the time spent on the stock payload-running view.

Before-state evidence:

- `04-refresh-500ms-before.png` — stock login/loading view.
- `05-refresh-7500ms-before.png` — partially restored page with raw control text.
- `06-refresh-15500ms-before.png` — late installed-payload fetch failure.
- `01-threat-before.png`, `02-evidence-before.png`, and
  `03-evidence-detail-before.png` — the pre-fix flow used for transition checks.

## Implemented experience fixes

- One Virtual Pager input is admitted until a new rendered revision arrives;
  the device queue also holds only one pending press.
- Buttons show short pressed feedback, expose useful accessible names, and work
  from Arrow, Enter, and Escape keys.
- Screen polling has a bounded abort/reconnect path and resets on page show,
  network return, and tab visibility.
- Refresh immediately focuses the real Pager shell and hides stock login,
  loading, terminal, and payload-portal layers while DEFCON Defense is active.
- Physical input arms 1.2 seconds after native startup, preventing the launch
  gesture from becoming the first in-app command.
- The renderer starts before monitoring libraries load and continues reclaiming
  the framebuffer only if another process displaces its pixels.

## Accepted final flow

1. General entry: `28-v49-cold-ready.png` and `36-v49-general-visible.png`.
2. Browser refresh: `29-v49-refresh-general.png`; measured recovery was 1.223 s
   total and did not expose the stock login/loading flow.
3. Threat detail: `30-v49-threat.png`.
4. PCAP browser: `31-v49-evidence.png`.
5. PCAP detail and verification action: `32-v49-detail.png`.
6. Physical Down selected Live RF: `34-v49-physical-down.png`.
7. Two simultaneous Right presses ended on one Evidence screen:
   `35-v49-double-right.png`.

## Visual and accessibility review

Strengths:

- The approved retro-security hierarchy, color semantics, dense information
  layout, contained dynamic text, and button legends remain unchanged.
- Focused mode removes unrelated browser chrome without altering the real Pager
  body or the application canvas.
- All six visual Pager controls have names and keyboard equivalents.

Residual constraint:

- Physical navigation intentionally ignores the first 1.2 seconds of a launch;
  the designed screen is already visible during that brief arming window.

Evidence limits:

- Hardware checks cover one connected Pager over its local USB network.
- The live state was clear-threat with imported legacy captures. High-threat
  and active-capture visual fidelity remains covered by the deterministic,
  equal-size comparisons in `docs/ui-v4/qa/`.
