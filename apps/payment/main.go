// payment: charges an order. Released with BLUE-GREEN (see gitops values):
// money-moving code gets a full preview stack + pre-promotion analysis and an
// atomic switch, instead of a gradual canary that would mix versions.
//
// Demonstrates: idempotency keys (safe retries from Istio / clients),
// fault injection via SIMULATED_ERROR_RATE so you can watch Argo Rollouts
// analysis fail and abort a release, graceful shutdown.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	mrand "math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var version = "dev"

type ChargeRequest struct {
	OrderID     string `json:"orderId"`
	AmountCents int64  `json:"amountCents"`
	Currency    string `json:"currency"`
	CardToken   string `json:"cardToken"`
}

type ChargeResponse struct {
	PaymentID string `json:"paymentId"`
	OrderID   string `json:"orderId"`
	Status    string `json:"status"` // approved | declined
	Reason    string `json:"reason,omitempty"`
}

var (
	httpRequests = newCounterVec("http_requests_total", "HTTP requests by route, method and status code.", "route", "method", "code")
	httpDuration = newHistogramVec("http_request_duration_seconds", "HTTP request latency.", "route", "method")
	charges      = newCounterVec("payment_charges_total", "Charges by outcome.", "status")
	buildInfo    = newCounterVec("app_build_info", "Build information (always 1).", "version")
)

type server struct {
	mu          sync.Mutex
	idempotency map[string]ChargeResponse // production: Redis/Postgres with TTL
	errorRate   float64
}

func (s *server) charge(w http.ResponseWriter, r *http.Request) {
	if s.errorRate > 0 && mrand.Float64() < s.errorRate {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "simulated failure"})
		return
	}
	key := r.Header.Get("Idempotency-Key")
	if key != "" {
		s.mu.Lock()
		prev, seen := s.idempotency[key]
		s.mu.Unlock()
		if seen {
			writeJSON(w, http.StatusOK, prev)
			return
		}
	}

	var req ChargeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if req.OrderID == "" || req.AmountCents <= 0 || req.CardToken == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "orderId, amountCents and cardToken are required"})
		return
	}

	resp := ChargeResponse{PaymentID: "pay_" + randomID(), OrderID: req.OrderID, Status: "approved"}
	if req.CardToken == "tok_decline" {
		resp.Status, resp.Reason = "declined", "card_declined"
	}
	charges.Inc(resp.Status)

	if key != "" {
		s.mu.Lock()
		s.idempotency[key] = resp
		s.mu.Unlock()
	}
	writeJSON(w, http.StatusOK, resp)
}

func newMux(s *server, ready *atomic.Bool) *http.ServeMux {
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
	mux.HandleFunc("POST /api/payments/charge", instrument("/api/payments/charge", s.charge))
	return mux
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	buildInfo.Inc(version)
	rate, _ := strconv.ParseFloat(os.Getenv("SIMULATED_ERROR_RATE"), 64)
	s := &server{idempotency: map[string]ChargeResponse{}, errorRate: rate}

	var ready atomic.Bool
	ready.Store(true)
	srv := &http.Server{Addr: ":" + envOr("PORT", "8080"), Handler: newMux(s, &ready),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second}

	go func() {
		slog.Info("starting", "service", "payment", "version", version, "simulatedErrorRate", rate)
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

func randomID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
