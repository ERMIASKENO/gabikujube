package main

import "testing"

func TestQuote(t *testing.T) {
	cases := []struct {
		name string
		in   QuoteRequest
		want int64
	}{
		{"domestic single item", QuoteRequest{Country: "PL", Items: 1}, 499},
		{"eu-west two items", QuoteRequest{Country: "FR", Items: 2}, 949},
		{"free shipping threshold", QuoteRequest{Country: "DE", Items: 5}, 0},
		{"rest of world", QuoteRequest{Country: "US", Items: 1}, 1499},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := quote(tc.in).CostCents; got != tc.want {
				t.Fatalf("got %d want %d", got, tc.want)
			}
		})
	}
}
