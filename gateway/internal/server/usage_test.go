package server

import (
	"testing"

	"agmente/gateway/internal/jsonv"
)

// usageFromUpdate reads only whole, non-negative used and size, and a cost whose amount is finite
// and non-negative. Anything else is left out, never estimated (C1).
func TestUsageFromUpdate(t *testing.T) {
	parse := func(s string) (ok bool, used, size int64, amount *float64, currency *string) {
		v, err := jsonv.Parse([]byte(s))
		if err != nil {
			t.Fatal(err)
		}
		u, ok := usageFromUpdate(v)
		return ok, u.Used, u.Size, u.CostAmount, u.CostCurrency
	}
	ok, used, size, amount, currency := parse(`{"used":1200,"size":200000,"cost":{"amount":0.42,"currency":"USD"}}`)
	if !ok || used != 1200 || size != 200000 || amount == nil || *amount != 0.42 || currency == nil || *currency != "USD" {
		t.Fatalf("full update: ok=%v used=%d size=%d", ok, used, size)
	}
	ok, _, _, amount, currency = parse(`{"used":5,"size":10}`)
	if !ok || amount != nil || currency != nil {
		t.Fatalf("no cost: want no cost fields, got amount=%v currency=%v", amount, currency)
	}
	ok, _, _, amount, _ = parse(`{"used":5,"size":10,"cost":{"amount":-1,"currency":"USD"}}`)
	if !ok || amount != nil {
		t.Fatalf("a negative cost is dropped, the usage is kept")
	}
	ok, _, _, amount, currency = parse(`{"used":5,"size":10,"cost":{"amount":1,"currency":"TOOLONGCODE"}}`)
	if !ok || amount == nil || currency != nil {
		t.Fatalf("a currency over %d characters is dropped, the amount is kept", maxCurrencyLen)
	}
	for _, bad := range []string{
		`{"used":5}`,
		`{"size":10}`,
		`{"used":"5","size":10}`,
		`{"used":5.5,"size":10}`,
		`{"used":-5,"size":10}`,
		`{"used":5,"size":-10}`,
		`{}`,
	} {
		if ok, _, _, _, _ := parse(bad); ok {
			t.Errorf("%s: want refused", bad)
		}
	}
}
