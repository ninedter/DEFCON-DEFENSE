package main

import "strings"

// Name keyword table: the sanitized upper-case advertised name is matched
// against these rows in order; the first match wins.

type nameMode byte

const (
	nmSub      nameMode = iota // substring
	nmPrefix                   // prefix
	nmWord                     // whole word (non-alphanumeric or edge on both sides)
	nmModel                    // prefix of a short single-word name (e.g. Fire TV "AFTMM")
	nmDirectHP                 // Wi-Fi Direct style "DIRECT-xx-... HP ..." printer names
)

type nameRule struct {
	pat         string
	mode        nameMode
	brand, kind string
}

func nameWordMatch(name, pat string) bool {
	alnum := func(c byte) bool { return c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' }
	for from := 0; ; {
		i := strings.Index(name[from:], pat)
		if i < 0 {
			return false
		}
		i += from
		end := i + len(pat)
		if (i == 0 || !alnum(name[i-1])) && (end == len(name) || !alnum(name[end])) {
			return true
		}
		from = i + 1
	}
}

func (r nameRule) match(name string) bool {
	switch r.mode {
	case nmDirectHP:
		return strings.HasPrefix(name, "DIRECT-") && strings.Contains(name, "HP")
	case nmPrefix:
		return strings.HasPrefix(name, r.pat)
	case nmWord:
		return nameWordMatch(name, r.pat)
	case nmModel:
		w := name
		if i := strings.IndexByte(w, ' '); i >= 0 {
			w = w[:i]
		}
		return strings.HasPrefix(name, r.pat) && len(w) <= 7
	}
	return strings.Contains(name, r.pat)
}

func sub(p, b, k string) nameRule    { return nameRule{p, nmSub, b, k} }
func pre(p, b, k string) nameRule    { return nameRule{p, nmPrefix, b, k} }
func word(p, b, k string) nameRule   { return nameRule{p, nmWord, b, k} }
func modelP(p, b, k string) nameRule { return nameRule{p, nmModel, b, k} }

var nameRules = []nameRule{
	sub("AIRPODS", "APPLE", "AIRPODS"), sub("BEATS", "BEATS", "AUDIO"),
	sub("IPHONE", "APPLE", "PHONE"), sub("IPAD", "APPLE", "TABLET"),
	sub("MACBOOK", "APPLE", "COMPUTER"), sub("MAGIC KEYBOARD", "APPLE", "KEYBOARD"),
	sub("MAGIC MOUSE", "APPLE", "MOUSE"), sub("MAGIC TRACKPAD", "APPLE", "TRACKPAD"),
	sub("APPLE WATCH", "APPLE", "WATCH"),
	sub("GALAXY BUDS", "SAMSUNG", "EARBUDS"), sub("GALAXY WATCH", "SAMSUNG", "WATCH"),
	sub("GALAXY TAB", "SAMSUNG", "TABLET"), sub("GALAXY ", "SAMSUNG", "PHONE"),
	sub("[TV] SAMSUNG", "SAMSUNG", "TV"), sub("SAMSUNG TV", "SAMSUNG", "TV"), pre("[TV]", "SAMSUNG", "TV"),
	sub("[LG]", "LG", "TV"), sub("LG TV", "LG", "TV"), sub("WEBOS", "LG", "TV"),
	sub("SAMSUNG", "SAMSUNG", "OTHER"),
	sub("JBL", "JBL", "SPEAKER"),
	word("BOSE", "BOSE", "AUDIO"), sub("LE-BOSE", "BOSE", "AUDIO"),
	word("SONY", "SONY", "AUDIO"), pre("WH-", "SONY", "AUDIO"), pre("WF-", "SONY", "AUDIO"),
	pre("LE_WH-", "SONY", "AUDIO"), pre("LE_WF-", "SONY", "AUDIO"),
	sub("PIXEL BUDS", "GOOGLE", "EARBUDS"), sub("PIXEL", "GOOGLE", "PHONE"),
	word("NEST", "GOOGLE", "SMART HOME"), sub("GOOGLE HOME", "GOOGLE", "SPEAKER"),
	sub("CHROMECAST", "GOOGLE", "TV"),
	sub("FIRE TV", "AMAZON", "TV"), sub("FIRETV", "AMAZON", "TV"), modelP("AFT", "AMAZON", "TV"),
	word("ECHO", "AMAZON", "SPEAKER"), sub("KINDLE", "AMAZON", "TABLET"),
	sub("FITBIT", "FITBIT", "FITNESS"), sub("CHARGE 5", "FITBIT", "FITNESS"),
	sub("CHARGE 6", "FITBIT", "FITNESS"), word("VERSA", "FITBIT", "FITNESS"),
	word("INSPIRE", "FITBIT", "FITNESS"),
	sub("GARMIN", "GARMIN", "WATCH"), sub("FORERUNNER", "GARMIN", "WATCH"),
	sub("FENIX", "GARMIN", "WATCH"), word("VENU", "GARMIN", "WATCH"), sub("VIVOACTIVE", "GARMIN", "WATCH"),
	sub("MI BAND", "XIAOMI", "FITNESS"), sub("SMART BAND", "XIAOMI", "FITNESS"),
	sub("AMAZFIT", "ZEPP", "WATCH"),
	sub("HUAWEI", "HUAWEI", "OTHER"), sub("HONOR", "HONOR", "OTHER"),
	sub("ONEPLUS", "ONEPLUS", "PHONE"), word("OPPO", "OPPO", "PHONE"),
	sub("REDMI", "XIAOMI", "PHONE"), sub("XIAOMI", "XIAOMI", "OTHER"),
	sub("MX MASTER", "LOGITECH", "INPUT"), sub("MX KEYS", "LOGITECH", "INPUT"),
	sub("MX ANYWHERE", "LOGITECH", "INPUT"), pre("LOGI", "LOGITECH", "INPUT"),
	sub("JABRA", "JABRA", "HEADSET"),
	word("POLY", "POLY", "HEADSET"), sub("PLANTRONICS", "POLY", "HEADSET"), sub("BACKBEAT", "POLY", "HEADSET"),
	sub("SENNHEISER", "SENNHEISER", "AUDIO"), sub("MOMENTUM", "SENNHEISER", "AUDIO"),
	sub("SOUNDCORE", "ANKER", "AUDIO"), sub("ANKER", "ANKER", "AUDIO"),
	sub("SKULLCANDY", "SKULLCANDY", "AUDIO"), sub("MARSHALL", "MARSHALL", "SPEAKER"),
	sub("UE BOOM", "LOGITECH", "SPEAKER"), sub("WONDERBOOM", "LOGITECH", "SPEAKER"),
	sub("MEGABOOM", "LOGITECH", "SPEAKER"),
	sub("SONOS", "SONOS", "SPEAKER"),
	word("TILE", "TILE", "TRACKER"), sub("CHIPOLO", "CHIPOLO", "TRACKER"), sub("SMARTTAG", "SAMSUNG", "TRACKER"),
	sub("NANOLEAF", "NANOLEAF", "LIGHT"), sub("PHILIPS HUE", "PHILIPS", "LIGHT"), word("HUE", "PHILIPS", "LIGHT"),
	sub("GOVEE", "GOVEE", "LIGHT"), pre("IHOSTER", "GOVEE", "LIGHT"), pre("GVH", "GOVEE", "LIGHT"),
	sub("WYZE", "WYZE", "SMART HOME"), word("RING", "AMAZON", "SMART HOME"),
	sub("TESLA", "TESLA", "CAR"), word("OURA", "OURA", "RING"),
	sub("WHOOP", "WHOOP", "FITNESS"), sub("POLAR", "POLAR", "FITNESS"), sub("PELOTON", "PELOTON", "FITNESS"),
	word("XBOX", "MICROSOFT", "GAME"), sub("SURFACE", "MICROSOFT", "COMPUTER"),
	sub("SWITCH", "NINTENDO", "GAME"), sub("JOY-CON", "NINTENDO", "GAME"), sub("PRO CONTROLLER", "NINTENDO", "GAME"),
	sub("DUALSENSE", "SONY", "GAME"), sub("DUALSHOCK", "SONY", "GAME"), sub("WIRELESS CONTROLLER", "SONY", "GAME"),
	pre("HP ", "HP", "PRINTER"), {"DIRECT-HP", nmDirectHP, "HP", "PRINTER"},
	sub("CANON", "CANON", "PRINTER"), sub("EPSON", "EPSON", "PRINTER"), sub("BROTHER", "BROTHER", "PRINTER"),
	word("ROKU", "ROKU", "TV"), sub("VIZIO", "VIZIO", "TV"), word("TCL", "TCL", "TV"), sub("HISENSE", "HISENSE", "TV"),
	sub("YEALINK", "YEALINK", "PHONE"),
	word("META", "META", "VR"), word("QUEST", "META", "VR"), sub("OCULUS", "META", "VR"),
	sub("RAY-BAN", "META", "GLASSES"),
}

// nameKeyword returns the brand and kind of the first matching rule.
func nameKeyword(name string) (brand, kind string) {
	if name == "" {
		return "", ""
	}
	for _, r := range nameRules {
		if r.match(name) {
			return r.brand, r.kind
		}
	}
	return "", ""
}
