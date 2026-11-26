// product-catalog: read-heavy catalog API.
// Demonstrates: Go 1.22+ routing, Prometheus metrics, structured JSON logs,
// readiness that flips to false on SIGTERM (so the endpoint is removed from
// Service/Envoy before the process stops), and graceful shutdown.
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
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

// version is injected at build time: -ldflags "-X main.version=<git sha>"
var version = "dev"

type Product struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Category    string `json:"category"`
	PriceCents  int64  `json:"priceCents"`
	Currency    string `json:"currency"`
	ImageURL    string `json:"imageUrl"`
}

var catalog = []Product{
	{"sku-1001", "Trail Running Shoes", "Lightweight shoes with grippy outsole", "footwear", 8999, "EUR", "/img/shoes.svg"},
	{"sku-1002", "Merino Hoodie", "Warm, breathable, odour resistant", "apparel", 6999, "EUR", "/img/hoodie.svg"},
	{"sku-1003", "Insulated Bottle 750ml", "Keeps drinks cold for 24h", "accessories", 2499, "EUR", "/img/bottle.svg"},
	{"sku-1004", "Daypack 22L", "Water-resistant pack with laptop sleeve", "bags", 7499, "EUR", "/img/pack.svg"},
	{"sku-1005", "Headlamp 400lm", "USB-C rechargeable headlamp", "accessories", 3999, "EUR", "/img/lamp.svg"},
	{"sku-1006", "Rain Shell Jacket", "3-layer waterproof shell", "apparel", 14999, "EUR", "/img/jacket.svg"},
}

var (
	httpRequests = newCounterVec("http_requests_total", "HTTP requests by route, method and status code.", "route", "method", "code")
	httpDuration = newHistogramVec("http_request_duration_seconds", "HTTP request latency.", "route", "method")
	buildInfo    = newCounterVec("app_build_info", "Build information (always 1).", "version")
)

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

func listProducts(w http.ResponseWriter, r *http.Request) {
	category := r.URL.Query().Get("category")
	q := strings.ToLower(r.URL.Query().Get("q"))
	out := make([]Product, 0, len(catalog))
	for _, p := range catalog {
		if category != "" && p.Category != category {
			continue
		}
		if q != "" && !strings.Contains(strings.ToLower(p.Name+" "+p.Description), q) {
			continue
		}
		out = append(out, p)
	}
	writeJSON(w, http.StatusOK, out)
}

func getProduct(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	for _, p := range catalog {
		if p.ID == id {
			writeJSON(w, http.StatusOK, p)
			return
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "product not found"})
}

func newMux(ready *atomic.Bool) *http.ServeMux {
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
	mux.HandleFunc("GET /api/products", instrument("/api/products", listProducts))
	mux.HandleFunc("GET /api/products/{id}", instrument("/api/products/{id}", getProduct))
	return mux
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)
	buildInfo.Inc(version)

	port := envOr("PORT", "8080")
	var ready atomic.Bool
	ready.Store(true)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           newMux(&ready),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		slog.Info("starting", "service", "product-catalog", "port", port, "version", version)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	<-ctx.Done()

	// 1) fail readiness so kube-proxy/Envoy stop sending new requests
	ready.Store(false)
	time.Sleep(durationEnv("DRAIN_SECONDS", 5))
	// 2) finish in-flight requests
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("graceful shutdown failed", "err", err)
	}
	slog.Info("stopped")
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func durationEnv(k string, defSeconds int) time.Duration {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil {
		return time.Duration(v) * time.Second
	}
	return time.Duration(defSeconds) * time.Second
}
