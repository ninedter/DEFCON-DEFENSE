/* DEFCON Defense Virtual Pager screen bridge.
 *
 * The stock Pager WebSocket shows the firmware-owned canvas. While the custom
 * full-screen application owns the physical framebuffer, this bridge displays
 * the exact same application canvas from its local, read-only PNG endpoint.
 * It automatically falls back to the stock WebSocket when the app exits.
 */
(() => {
  if (window.__defconDefenseBridgeInstalled) return;
  window.__defconDefenseBridgeInstalled = true;
  window.__defconDefenseBridgeVersion = "4.2.3";

  const endpoint = `${window.location.protocol}//${window.location.hostname}:1472/screen.png`;
  let active = false;
  let objectUrl = null;
  let failures = 0;
  let guardedSocket = null;
  let stockSocketHandler = null;
  let etag = "";
  let inFlight = false;

  const stockRenderer = window.renderRGBAFrame;
  if (typeof stockRenderer === "function") {
    window.renderRGBAFrame = (bytes) => {
      if (!active) stockRenderer(bytes);
    };
  }

  function guardStockSocket() {
    if (typeof screenws === "undefined" || !screenws || screenws === guardedSocket) return;
    guardedSocket = screenws;
    stockSocketHandler = screenws.onmessage;
    screenws.onmessage = (event) => {
      if (!active && typeof stockSocketHandler === "function") {
        stockSocketHandler.call(screenws, event);
      }
    };
  }

  async function refresh() {
    if (inFlight) return;
    const pager = document.getElementById("pager");
    if (!pager) return;
    guardStockSocket();
    inFlight = true;
    try {
      const revision = etag ? `&rev=${encodeURIComponent(etag)}` : "";
      const response = await fetch(`${endpoint}?wait=1${revision}`, {cache: "no-store"});
      if (response.status === 304) {
        active = true;
        failures = 0;
        return;
      }
      if (!response.ok) throw new Error("custom screen unavailable");
      etag = response.headers.get("ETag") || etag;
      const nextUrl = URL.createObjectURL(await response.blob());
      const priorUrl = objectUrl;
      objectUrl = nextUrl;
      active = true;
      failures = 0;
      pager.style.display = "block";
      pager.src = nextUrl;
      if (priorUrl) setTimeout(() => URL.revokeObjectURL(priorUrl), 500);
    } catch (_) {
      failures += 1;
      if (failures >= 3) active = false;
    } finally {
      inFlight = false;
      setTimeout(refresh, active ? 0 : 250);
    }
  }

  refresh();
})();
