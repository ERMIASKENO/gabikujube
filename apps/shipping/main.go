// shipping: quotes shipping cost and ETA. Released with CANARY.
// SIMULATED_LATENCY_MS lets you ship a "slow" version and watch the
// p95-latency analysis in the ClusterAnalysisTemplate abort the rollout.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
)

var version = "dev"

type QuoteRequest struct {
	Country string `json:"country"`
	Items   int    `json:"items"`
}

type QuoteResponse struct {
	Carrier   string `json:"carrier"`
	CostCents int64  `json:"costCents"`
	Currency  string `json:"currency"`
	ETADays   int    `json:"etaDays"`
}

var (
	httpRequests = newCounterVec("http_requests_total", "HTTP requests by route, method and status code.", "route", "method", "code")
	httpDuration = newHistogramVec("http_request_duration_seconds", "HTTP request latency.", "route", "method")
	buildInfo    = newCounterVec("app_build_info", "Build information (always 1).", "version")
)

// quote is a pure function, so it is trivially unit-testable.
func quote(req QuoteRequest) QuoteResponse {
	base, eta := int64(1499), 5
	switch req.Country {
	case "PL", "DE", "CZ", "SK", "LT":
		base, eta = 499, 2
	case "FR", "NL", "BE", "AT", "IT", "ES":
		base, eta = 799, 3
	}
	extra := int64(0)
	if req.Items > 1 {
		extra = int64(req.Items-1) * 150
	}
	if req.Items >= 5 && (req.Country == "PL" || req.Country == "DE") {
		return QuoteResponse{Carrier: "DHL", CostCents: 0, Currency: "EUR", ETADays: eta} // free shipping
	}
	return QuoteResponse{Carrier: "DHL", CostCents: base + extra, Currency: "EUR", ETADays: eta}
}

func newMux(ready *atomic.Bool, latency time.Duration) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": version})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !ready.Load() {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	})
	mux.Handle("GET /metrics", metricsHandler())
	mux.HandleFunc("POST /api/shipping/quote", instrument("/api/shipping/quote", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(latency)
		var req QuoteRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<14)).Decode(&req); err != nil || req.Country == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "country is required"})
			return
		}
		writeJSON(w, http.StatusOK, quote(req))
	}))
	return mux
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	buildInfo.Inc(version)
	ms, _ := strconv.Atoi(os.Getenv("SIMULATED_LATENCY_MS"))

	var ready atomic.Bool
	ready.Store(true)
	srv := &http.Server{Addr: ":" + envOr("PORT", "8080"), Handler: newMux(&ready, time.Duration(ms)*time.Millisecond),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second}

	go func() {
		slog.Info("starting", "service", "shipping", "version", version)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	<-ctx.Done()
	ready.Store(false)
	time.Sleep(5 * time.Second)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) { r.code = code; r.ResponseWriter.WriteHeader(code) }

func instrument(route string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		h(rec, r)
		httpRequests.Inc(route, r.Method, strconv.Itoa(rec.code))
		httpDuration.Observe(time.Since(start).Seconds(), route, r.Method)
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
