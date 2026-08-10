# DEFCON Defense

The single visible Pager entry point for the defensive payload package. It
combines passive 2.4/5 GHz monitoring, local alerting, evidence review, and the
curated manual tools in one menu.

Open it from **Payloads > General > DEFCON Defense** to:

- configure Recon to listen on 2.4 and 5 GHz;
- watch the continuously refreshing **Live RF Traffic** dashboard with AP and
  packet totals, signal-quality bars, and 2.4/5 GHz activity;
- browse **Browse Recon Networks** with the native arrow-button list to select,
  focus/capture, or watch a specific AP;
- keep **Threat Activity Live** continuously refreshing from Recon; malicious
  deauth/disassociation and watched/trusted identity indicators are rendered
  prominently in red while the page remains open;
- open the separate **Investigate Threats** native list with arrows and green A
  to select a current indicator for focused passive capture;
- use the Pager-native arrows to navigate, green A to confirm/open, and red B
  to cancel/back;
- watch selected networks without a baseline, or optionally create a reviewed
  BSSID baseline for broader new-AP detection;
- monitor continuously for trusted-network impersonation, trusted AP identity
  changes, unexpected channel changes, and persistent strong new APs;
- receive ringtone/vibration alerts and review timestamped findings; recent
  deauth/disassociation events and identity anomalies are shown in red;
- open the non-transmitting hostile-RF emergency checklist;
- confirm that both automatic alert handlers are armed;
- launch PORT Alert or ICMP Alert;
- launch Find Hackers or Alien AP; and
- test the alert ringtone and vibration.

The automatic handlers remain in their firmware-required event directories:

- `alerts/deauth_flood_detected/defcon_sentry`
- `alerts/pineapple_client_connected/defcon_honeypot`

Enable PineAP recon/listening for the automatic deauth detector. The honeypot
also requires an intentional neutral open AP.

## Trusted networks

Before the event, edit `trusted_aps.conf` and add each authorized SSID/BSSID
pair. The third field is a comma-separated channel allowlist or `*`:

```text
SOC-Operations|00:11:22:33:44:55|1,6,11
SOC-Operations|00:11:22:33:44:66|36,40,44,48
```

Never put a PSK, password, token, or other secret in this file.

## Monitoring behavior

- Trusted SSID/BSSID or channel mismatches alert immediately.
- An unknown BSSID must be at least `-72 dBm` and appear in two scans within
  60 seconds before it alerts. This reduces noise at crowded venues.
- Per-finding alerts cool down for five minutes.
- Watched networks, the optional baseline, and findings are stored under
  `/root/loot/defcon_defense/`. Firmware-native focused PCAPs are saved under
  `/root/loot/pcap/`.

The baseline is optional. Create it only after reviewing the current
environment. A device already present in the baseline is treated as previously
seen; watched-network and trusted-network rules still take precedence.

The monitor only reads Recon observations. It does not send deauthentication,
disassociation, interference, or other countermeasure traffic.
