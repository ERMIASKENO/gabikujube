package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestListAndGet(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	srv := httptest.NewServer(newMux(&ready))
	defer srv.Close()

	res, err := http.Get(srv.URL + "/api/products?category=apparel")
	if err != nil || res.StatusCode != http.StatusOK {
		t.Fatalf("list failed: %v %v", err, res)
	}
	var items []Product
	if err := json.NewDecoder(res.Body).Decode(&items); err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("expected 2 apparel items, got %d", len(items))
	}

	res, _ = http.Get(srv.URL + "/api/products/does-not-exist")
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", res.StatusCode)
	}
}

func TestReadinessFlipsWhenDraining(t *testing.T) {
	var ready atomic.Bool
	srv := httptest.NewServer(newMux(&ready))
	defer srv.Close()
	res, _ := http.Get(srv.URL + "/readyz")
	if res.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 while draining, got %d", res.StatusCode)
	}
}
