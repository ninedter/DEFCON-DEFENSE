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
  window.__defconDefenseBridgeVersion = "4.0.1";

  const endpoint = `${window.location.protocol}//${window.location.hostname}:1472/screen.png`;
  let active = false;
  let objectUrl = null;
  let failures = 0;
  let guardedSocket = null;
  let stockSocketHandler = null;

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
    const pager = document.getElementById("pager");
    if (!pager) return;
    guardStockSocket();
    try {
      const response = await fetch(`${endpoint}?t=${Date.now()}`, {cache: "no-store"});
      if (!response.ok) throw new Error("custom screen unavailable");
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
    }
  }

  setInterval(refresh, 250);
  refresh();
})();
