# DEFCON Defense Pager v3 Design QA

## Comparison Target

- Source visual truth:
  - General screen: `pineapple-pager/docs/ui-v3/references/01-general-screen-reference.png`
  - Threat detail: `pineapple-pager/docs/ui-v3/references/02-threat-detail-reference.png`
  - PCAP browser: `pineapple-pager/docs/ui-v3/references/03-pcap-browser-reference.png`
- Rendered implementation:
  - General screen: `pineapple-pager/docs/ui-v3/01-general-screen.png`
  - Threat detail: `pineapple-pager/docs/ui-v3/02-threat-detail-screen.png`
  - PCAP browser: `pineapple-pager/docs/ui-v3/03-pcap-browser-screen.png`
  - PCAP detail: `pineapple-pager/docs/ui-v3/04-pcap-detail-screen.png`
- Full Virtual Pager evidence:
  - `pineapple-pager/docs/ui-v3/01-general-screen-full.png`
  - `pineapple-pager/docs/ui-v3/03-pcap-evidence-full.png`
  - `pineapple-pager/docs/ui-v3/04-pcap-evidence-detail-full.png`
- Combined comparison evidence:
  - `pineapple-pager/docs/ui-v3/qa/01-general-comparison.png`
  - `pineapple-pager/docs/ui-v3/qa/02-threat-comparison.png`
  - `pineapple-pager/docs/ui-v3/qa/03-pcap-comparison.png`

## Viewport and Normalization

- Hardware design target: 480 x 222 Pager LCD.
- In-app Browser screenshot viewport: 615 x 814 CSS pixels at device scale factor 1.
- Virtual Pager LCD content region: 391 x 181 CSS pixels at device scale factor 1.
- Source images: 1844 x 853 or 1846 x 852 pixels, downsampled to 960 x 444 for comparison.
- General and PCAP implementation captures: 391 x 181 pixels, upsampled to 960 x 444 for equal-size comparison.
- Threat implementation capture: 391 x 152 visible pixels from the connected-device HIGH-threat state, centered on a 960 x 444 comparison canvas because that earlier capture was vertically offset.
- All comparisons remove the Pager bezel and browser chrome so the UI content, hierarchy, copy, and state can be judged directly.

## State and Interactions Tested

- General screen with passive monitoring active, 74 APs visible, no current threat, and three stored PCAPs.
- HIGH threat detail for a confirmed deauthentication/disassociation event, including affected SSID, BSSID, band, channel, signal, packet count, evidence state, and button guidance.
- PCAP evidence library with three imported captures.
- Evidence action menu, evidence details, SHA-256 status, back navigation, and return to the general screen.
- Physical navigation mapping verified in Virtual Pager: UP/DOWN moves selection, A opens or acts, B returns, and LEFT/RIGHT is reserved for paging or related detail navigation.
- The connected Pager was left running on the verified general screen after the test.

## Findings

No actionable P0, P1, or P2 findings remain.

- [P3] Native firmware presentation differs from the high-fidelity visual direction.
  - Location: all three Pager screens.
  - Evidence: the left sides of the comparison images use a custom full-screen grid, while the implementation uses the Pager firmware's native `LIST_PICKER`, `LOG`, and `PROMPT` surfaces.
  - Impact: the implementation cannot reproduce the mock's multi-column table, custom boxed controls, or exact pixel font without replacing stable firmware UI primitives.
  - Classification: accepted hardware constraint. The native implementation preserves the approved information hierarchy, states, semantic colors, and button behavior while remaining compatible with the Pager.

## Required Fidelity Surfaces

- Fonts and typography: native Pager mono fonts are used consistently. Headings, selected rows, severity text, and button hints remain readable at the physical screen size. Truncation occurs only where the firmware picker intentionally ellipsizes long secondary text; detailed information remains available one level deeper.
- Spacing and layout rhythm: the four primary general-screen destinations remain above the fold. Threat detail uses one fact per line with no collisions. Evidence rows have consistent vertical spacing and the selected state is clear.
- Colors and tokens: yellow identifies titles/selection, red identifies malicious or high-severity state, green identifies active/saved/safe state, and cyan/white carry secondary data and navigation hints. Contrast is strong against the black or blue native surfaces.
- Image quality and asset fidelity: the product UI contains no decorative imagery or substituted placeholder assets. The only surrounding visual asset is the official Virtual Pager device frame, which is excluded from content comparisons.
- Copy and content: general status, threat explanation, affected network, evidence status, RF identifiers, timestamps, sizes, hashes, and download guidance use direct operational language. Dynamic legacy captures are explicitly labeled rather than misclassified.
- Accessibility and behavior: large physical buttons are the only interaction targets; every core action has a visible button mapping. Destructive deletion requires confirmation. Long-running PCAP hashing is explicit and on demand rather than blocking navigation.

## Comparison History

1. [P1] Concurrent foreground and background scans reused the same temporary snapshot name, producing a rename failure during on-device navigation.
   - Fix: snapshot names now include `BASHPID` and `RANDOM` so foreground and background jobs cannot collide.
   - Post-fix evidence: `pineapple-pager/docs/ui-v3/01-general-screen-full.png` shows the live general screen while background monitoring is active.
2. [P1] BusyBox field parsing allowed a PCAP state record to become multiline, which could prevent the evidence browser from resolving its current state.
   - Fix: state values are normalized to a single line and the automated test asserts the complete 13-field record.
   - Post-fix evidence: `pineapple-pager/docs/ui-v3/03-pcap-evidence-full.png` and `pineapple-pager/docs/ui-v3/04-pcap-evidence-detail-full.png` show successful library and detail navigation.
3. [P2] The original long header clipped in the native picker.
   - Fix: the screen title was reduced to `DEFCON Defense` and essential status was moved into concise menu rows.
   - Post-fix evidence: `pineapple-pager/docs/ui-v3/qa/01-general-comparison.png` shows the final uncut title and four primary destinations.
4. [P2] Importing existing PCAPs calculated every SHA-256 digest during startup, delaying the first useful screen.
   - Fix: existing captures import immediately; digest verification is available on demand from the evidence action menu.
   - Post-fix evidence: the general screen and three-entry evidence library open normally in the connected Virtual Pager flow.

## Focused Review

Separate focused-region images were not needed because each comparison is already a content-only LCD capture normalized to 960 x 444, making typography, state colors, selected rows, and operational copy directly readable. The additional PCAP detail screenshot verifies the dense metadata state that is not represented in the source browser mock.

## Implementation Checklist

- [x] General screen exposes the four approved primary destinations first.
- [x] Threat detail prioritizes severity, affected network, evidence state, and RF identifiers.
- [x] PCAP library, action menu, metadata detail, verification, download guidance, and confirmed deletion are reachable with Pager buttons.
- [x] Automatic capture is passive, bounded, deduplicated, quota-aware, and shared by the unified monitor and Deauth Sentry.
- [x] Connected-device navigation and final visual states are captured.
- [x] Automated build and behavior checks pass.

## Follow-up Polish

- If Hak5 adds a supported full-screen drawing API in a future firmware, the native screens could adopt more of the reference mock's multi-column density without sacrificing input reliability.

final result: passed
