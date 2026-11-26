package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func post(t *testing.T, url, key string, body any) ChargeResponse {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Idempotency-Key", key)
	res, err := http.DefaultClient.Do(req)
	if err != nil || res.StatusCode != http.StatusOK {
		t.Fatalf("charge failed: %v %v", err, res)
	}
	var out ChargeResponse
	_ = json.NewDecoder(res.Body).Decode(&out)
	return out
}

func TestChargeIsIdempotent(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	ts := httptest.NewServer(newMux(&server{idempotency: map[string]ChargeResponse{}}, &ready))
	defer ts.Close()

	body := ChargeRequest{OrderID: "o-1", AmountCents: 1000, Currency: "EUR", CardToken: "tok_visa"}
	first := post(t, ts.URL+"/api/payments/charge", "k-1", body)
	second := post(t, ts.URL+"/api/payments/charge", "k-1", body)
	if first.PaymentID != second.PaymentID {
		t.Fatalf("retry with same key must return same payment: %s != %s", first.PaymentID, second.PaymentID)
	}
}

func TestDecline(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	ts := httptest.NewServer(newMux(&server{idempotency: map[string]ChargeResponse{}}, &ready))
	defer ts.Close()
	out := post(t, ts.URL+"/api/payments/charge", "k-2",
		ChargeRequest{OrderID: "o-2", AmountCents: 1000, Currency: "EUR", CardToken: "tok_decline"})
	if out.Status != "declined" {
		t.Fatalf("expected declined, got %s", out.Status)
	}
}
