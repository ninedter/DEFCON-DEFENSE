package main

import (
	"fmt"
	"image"
	"strings"
	"time"
)

// btTypeHints explains the less obvious device types in plain English.
var btTypeHints = map[string]string{
	"AIRPODS":    "APPLE EARBUDS CASE/PODS",
	"FIND MY":    "OFFLINE FINDING BEACON",
	"NEARBY":     "IPHONE/IPAD/MAC NEARBY",
	"HANDOFF":    "APPLE HANDOFF ACTIVITY",
	"WATCH":      "APPLE WATCH",
	"HOTSPOT":    "PERSONAL HOTSPOT",
	"AIRDROP":    "AIRDROP SENDER",
	"AIRPLAY":    "AIRPLAY SPEAKER/TV",
	"HOMEKIT":    "HOMEKIT ACCESSORY",
	"WINDOWS":    "WINDOWS PC NEARBY",
	"SWIFT PAIR": "PAIRING-MODE ACCESSORY",
	"FAST PAIR":  "ANDROID FAST PAIR",
	"TRACKER":    "ITEM TRACKER",
	"SMARTTAG":   "SAMSUNG TRACKER",
	"EDDYSTONE":  "BEACON",
	"IBEACON":    "BEACON",
}

const (
	btListRight  = 256
	btCrumbCells = 26
	btPanelCells = 26
)

// fmtDBM renders a signal with its unit, or "--" when there is no data.
func fmtDBM(rssi int) string {
	if rssi <= -100 {
		return "--"
	}
	return fmt.Sprintf("%d DBM", rssi)
}

// btCrumb trims a breadcrumb from the left so the deepest part stays visible.
func btCrumb(s string, cells int) string {
	if len(s) <= cells {
		return s
	}
	return ".." + s[len(s)-(cells-2):]
}

func (u *ui) btBreadcrumb() string {
	switch u.btLevel {
	case btLevelTypes:
		return btCrumb("BRANDS > "+u.btBrand, btCrumbCells)
	case btLevelDevices, btLevelTrack:
		return btCrumb(u.btBrand+" > "+u.btType, btCrumbCells)
	}
	return "BRANDS"
}

func (u *ui) renderBTHeader(img *image.RGBA, s Snapshot, now time.Time) {
	renderTitle(img, "RF-BUDDY", 120)
	renderTabs(img, 2)
	status, limit := "BT N/A", 392
	if s.HasBT {
		status = fmt.Sprintf("%d DEV  %.0f ADV/S", len(s.BT), s.BTAdvPerSec)
	}
	if !s.LogPaused {
		limit = 430
	}
	drawTextBox(img, image.Rect(290, 3, limit, 20), 290, 3, trimCells(status, (limit-290)/textCellWidth), cyan, true, 1)
	renderClock(img, now, s.LogPaused)
}

func (u *ui) renderBT(img *image.RGBA, s Snapshot, now time.Time) {
	u.renderBTHeader(img, s, now)
	vLine(img, 260, 24, 198, cyan2)
	if !s.HasBT {
		drawText(img, 6, 90, "BLUETOOTH UNAVAILABLE", dim, true, 1)
		renderFooter(img, hint{"B", "EXIT"}, "LEFT/RIGHT SEL", "UP/DN BAND", hint{"A", "OPEN"})
		return
	}
	drawTextBox(img, image.Rect(6, 24, 6+btCrumbCells*textCellWidth, 40), 6, 24, u.btBreadcrumb(), dim, true, 1)
	switch u.btLevel {
	case btLevelBrands:
		groups := GroupByBrand(s.BT)
		renderBTGroups(img, groups, u.btBrand, "NO DEVICES YET")
		if len(groups) > 0 {
			renderBTGroupPanel(img, s, "", groups[groupIndex(groups, u.btBrand)], false)
		}
		renderFooter(img, hint{"B", "EXIT"}, "LEFT/RIGHT SEL", "UP/DN BAND", hint{"A", "OPEN"})
	case btLevelTypes:
		groups := GroupByType(s.BT, u.btBrand)
		renderBTGroups(img, groups, u.btType, "NO DEVICES FOR BRAND")
		if len(groups) > 0 {
			renderBTGroupPanel(img, s, u.btBrand, groups[groupIndex(groups, u.btType)], true)
		}
		renderFooter(img, hint{"B", "BACK"}, "ARROWS SELECT", "", hint{"A", "OPEN"})
	default:
		list := u.btDevices(s)
		drawTextRightBox(img, image.Rect(214, 24, btListRight, 40), 24, "DBM", dim, true)
		if len(list) == 0 {
			drawText(img, 6, 90, "NO DEVICES OF THIS TYPE", dim, true, 1)
		} else {
			sel, _ := u.btIndex(list)
			top := max(0, sel-(btVisibleRows-1))
			for row := 0; row < btVisibleRows && top+row < len(list); row++ {
				d := list[top+row]
				y := 44 + row*16
				c := white
				if top+row == sel {
					c = yellow
					drawText(img, 6, y, ">", yellow, true, 1)
				}
				drawTextBox(img, image.Rect(14, y, 210, y+16), 14, y, trimCells(d.Label, 24), c, true, 1)
				drawTextRightBox(img, image.Rect(210, y, btListRight, y+16), y, fmtRSSI(d.RSSI), signalColor(d.RSSI), true)
			}
			renderBTPanel(img, list[sel], now)
		}
		renderFooter(img, hint{"B", "BACK"}, "ARROWS SELECT", "", hint{"A", "TRACK"})
	}
}

// renderBTGroups draws the brand/type list with a count column.
func renderBTGroups(img *image.RGBA, groups []BTGroup, cur, empty string) {
	drawTextRightBox(img, image.Rect(214, 24, btListRight, 40), 24, "DEV", dim, true)
	if len(groups) == 0 {
		drawText(img, 6, 90, empty, dim, true, 1)
		return
	}
	sel := groupIndex(groups, cur)
	top := max(0, sel-(btVisibleRows-1))
	for row := 0; row < btVisibleRows && top+row < len(groups); row++ {
		g := groups[top+row]
		y := 44 + row*16
		c := white
		if top+row == sel {
			c = yellow
			drawText(img, 6, y, ">", yellow, true, 1)
		}
		drawTextBox(img, image.Rect(14, y, 190, y+16), 14, y, trimCells(g.Name, 22), c, true, 1)
		drawTextRightBox(img, image.Rect(190, y, btListRight, y+16), y, fmt.Sprint(g.Count), c, true)
	}
}

// wrapParts packs comma-separated parts onto at most maxLines lines.
func wrapParts(s string, width, maxLines int) []string {
	var lines []string
	cur := ""
	for _, p := range strings.Split(s, ", ") {
		switch {
		case cur == "":
			cur = p
		case len(cur)+2+len(p) <= width:
			cur += ", " + p
		default:
			lines = append(lines, cur)
			cur = p
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	if len(lines) > maxLines {
		lines = lines[:maxLines]
	}
	return lines
}

// renderBTGroupPanel draws the summary of a brand (types=false) or of one
// type of a brand (types=true).
func renderBTGroupPanel(img *image.RGBA, s Snapshot, brand string, g BTGroup, types bool) {
	box := image.Rect(266, 24, 476, 198)
	title := g.Name
	if types {
		title = brand + " " + g.Name
	}
	drawTextBox(img, box, 266, 26, trimCells(title, btPanelCells), yellow, true, 1)
	metricRow(img, 44, "DEVICES", fmt.Sprint(g.Count), cyan)
	metricRow(img, 60, "STRONGEST", fmtDBM(g.Strongest), signalColor(g.Strongest))
	metricRow(img, 76, "ADV/S", fmt.Sprintf("%.1f", g.AdvPerSec), cyan)
	drawText(img, 266, 96, "TOP", white, true, 1)
	drawTextBox(img, box, 266, 112, trimCells(g.Top, btPanelCells), cyan, true, 1)
	if types {
		if h := btTypeHints[g.Name]; h != "" {
			drawTextBox(img, box, 266, 136, trimCells(h, btPanelCells), dim, true, 1)
		}
		return
	}
	drawText(img, 266, 136, "TYPES", white, true, 1)
	for i, l := range wrapParts(TypeBreakdown(s.BT, g.Name, 8), btPanelCells, 2) {
		drawTextBox(img, box, 266, 152+i*16, trimCells(l, btPanelCells), cyan, true, 1)
	}
}

func renderBTPanel(img *image.RGBA, d BLEDevice, now time.Time) {
	box := image.Rect(266, 24, 476, 198)
	drawTextBox(img, box, 266, 26, trimCells(d.Label, btPanelCells), yellow, true, 1)
	addr := d.Addr
	if len(addr) > 3 {
		addr = addr[3:]
	}
	kind := "PUBLIC"
	if d.Random {
		kind = "RANDOM"
	}
	name := d.Name
	if name == "" {
		name = "--"
	}
	tx := "--"
	if d.HasTx {
		tx = fmt.Sprintf("%d DBM", d.TxPower)
	}
	first := "--"
	if !d.FirstSeen.IsZero() {
		first = d.FirstSeen.Format("15:04:05")
	}
	metricRow(img, 44, "ADDR", addr, cyan)
	metricRow(img, 60, "TYPE", kind, cyan)
	metricRow(img, 76, "NAME", name, cyan)
	metricRow(img, 92, "SIGNAL", fmtDBM(d.RSSI), signalColor(d.RSSI))
	metricRow(img, 108, "PEAK", fmtDBM(d.Peak), cyan)
	metricRow(img, 124, "ADV/S", fmt.Sprintf("%.1f", d.AdvPerSec), cyan)
	metricRow(img, 140, "TX PWR", tx, cyan)
	metricRow(img, 156, "SEEN", fmt.Sprintf("%d S AGO", secondsAgo(d.LastSeen, now)), cyan)
	metricRow(img, 172, "FIRST", first, cyan)
}
