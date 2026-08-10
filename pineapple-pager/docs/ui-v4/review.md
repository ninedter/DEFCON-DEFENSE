# DEFCON Defense Pager UI v4 Review

This implementation turns the three approved designs into one native Pager application:

1. The general dashboard is the default screen and leads with monitoring and threat state.
2. The threat-detail screen separates the active alert, affected network, RF facts, and capture state.
3. The evidence browser lists saved PCAPs and opens a detail view with integrity verification and Virtual Pager download guidance.

The application renders at the Pager's native 480 x 222 resolution, reads live DEFCON Defense state, accepts physical and Virtual Pager button input, and mirrors its framebuffer to Virtual Pager without replacing the device's normal browser shell. A native firmware picker remains available as a fallback if the custom executable or framebuffer is unavailable.

## Design fidelity

The supplied images in `references/` are the visual source of truth. Deterministic renders are in `implementation/`, and equal-size side-by-side checks are in `qa/`. The final implementation preserves the dense retro-security presentation, strong alert hierarchy, cyan grid, yellow focus state, and green/red operational semantics of the designs.

## Defensive capture flow

When a high-confidence malicious event is confirmed, DEFCON Defense can begin a bounded passive PCAP capture immediately. Captures are stored on the Pager, indexed for browsing, limited by duration and storage quota, protected against overlapping capture jobs, and available for later download through Virtual Pager. SHA-256 is computed only when the operator requests verification so routine browsing remains responsive.
