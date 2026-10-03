package main

import "testing"

// Patterns below come from a 60 s office capture (2026-10-03) of devices the
// classifier could not name.

func parseADFor(t *testing.T, addr string, random bool, ad string) Advert {
	t.Helper()
	a := Advert{Addr: addr, Random: random}
	parseAD(hx(t, ad), &a)
	return a
}

func TestFindHubTagFromEddystoneFMDN(t *testing.T) {
	for _, frame := range []string{"40", "41"} { // normal / unwanted-tracking-protection mode
		// len 0x17: type 0x16, uuid FEAA, frame, 20-byte EID
		a := parseADFor(t, "7A:11:22:33:44:55", true,
			"1716AAFE"+frame+"0102030405060708090A0B0C0D0E0F1011121314")
		if a.SvcKind != "FIND HUB TAG" || a.BrandHint != "GOOGLE" {
			t.Fatalf("frame %s: svcKind=%q hint=%q, want FIND HUB TAG / GOOGLE", frame, a.SvcKind, a.BrandHint)
		}
	}
}

func TestUnknownAppleContinuityTypeIsNamed(t *testing.T) {
	a := parseADFor(t, "5A:00:00:00:00:01", true, "0DFF4C0016080102030405060708")
	if a.MfrKind != "CONTINUITY 16" {
		t.Fatalf("unknown Apple TLV 0x16: mfrKind=%q, want CONTINUITY 16", a.MfrKind)
	}
	// A known message type still wins over an unknown one in the same advert.
	a = parseADFor(t, "5A:00:00:00:00:01", true, "0EFF4C001C02AABB1005010203040A")
	if a.MfrKind != "NEARBY" {
		t.Fatalf("Nearby + unknown 0x1C: mfrKind=%q, want NEARBY", a.MfrKind)
	}
}

func TestCompanyIDThatIsTheOwnAddressIsIgnored(t *testing.T) {
	// The device writes its own MAC (0A:BC:...) where the company id belongs.
	a := parseADFor(t, "0A:BC:00:00:00:02", false, "07FF0ABC00000002")
	if a.Company != -1 {
		t.Fatalf("company = %04X, want -1 (it is the device's own address)", a.Company)
	}
	b := parseADFor(t, "0A:BC:00:00:00:02", false, "05FF4C0010AA")
	if b.Company != 0x004C {
		t.Fatalf("a real company id must be kept, got %04X", b.Company)
	}
}

func TestBrandFromASCIIIn128BitUUID(t *testing.T) {
	// UUID bytes (wire order) read backwards spell "PRIM-..AirohaBLE".
	a := parseADFor(t, "6E:01:02:03:04:05", true, "1107454C4261686F72694103AB2D4D495250")
	if a.BrandHint != "AIROHA" {
		t.Fatalf("hint = %q, want AIROHA", a.BrandHint)
	}
}

func TestClassifyFallbacks(t *testing.T) {
	// Member service UUID with no known meaning: say which service it is.
	c := classifyBLE(bleClassIn{addr: "37:00:00:00:00:03", random: true, company: -1, appearV: -1, services: []int{0xFEF3}}, true)
	if c.brand != "GOOGLE" || c.typ != "SVC FEF3" {
		t.Fatalf("FEF3: brand=%q type=%q, want GOOGLE / SVC FEF3", c.brand, c.typ)
	}
	// Audio SoC vendors almost only ship in earbuds and headphones.
	c = classifyBLE(bleClassIn{addr: "02:00:00:00:00:04", company: 0x07E3, appearV: -1}, true)
	if c.brand != "AIROHA" || c.typ != "AUDIO" {
		t.Fatalf("Airoha: brand=%q type=%q, want AIROHA / AUDIO", c.brand, c.typ)
	}
	// Brand hint from a 128-bit UUID beats a bare unassigned company id.
	c = classifyBLE(bleClassIn{addr: "6E:01:02:03:04:05", random: true, company: 0x69EF, hint: "AIROHA", appearV: -1}, true)
	if c.brand != "AIROHA" {
		t.Fatalf("unassigned id + AIROHA hint: brand=%q, want AIROHA", c.brand)
	}
}
