package main

// Minimal, dependency-free Prometheus text-format exporter (counter + histogram).
// Go services in this repo deliberately have zero third-party modules, which
// keeps images tiny and Trivy/Dependabot noise at zero. Swap for
// github.com/prometheus/client_golang if you need more metric types.

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
)

var defaultBuckets = []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5}

type counterVec struct {
	name, help string
	labels     []string
	mu         sync.Mutex
	values     map[string]float64
}

func newCounterVec(name, help string, labels ...string) *counterVec {
	c := &counterVec{name: name, help: help, labels: labels, values: map[string]float64{}}
	registry.add(c)
	return c
}

func (c *counterVec) Inc(lv ...string) {
	c.mu.Lock()
	c.values[labelKey(c.labels, lv)]++
	c.mu.Unlock()
}

func (c *counterVec) write(sb *strings.Builder) {
	c.mu.Lock()
	defer c.mu.Unlock()
	fmt.Fprintf(sb, "# HELP %s %s\n# TYPE %s counter\n", c.name, c.help, c.name)
	for _, k := range sortedKeys(c.values) {
		fmt.Fprintf(sb, "%s{%s} %g\n", c.name, k, c.values[k])
	}
}

type histogramVec struct {
	name, help string
	labels     []string
	buckets    []float64
	mu         sync.Mutex
	counts     map[string][]uint64
	sums       map[string]float64
	totals     map[string]uint64
}

func newHistogramVec(name, help string, labels ...string) *histogramVec {
	h := &histogramVec{name: name, help: help, labels: labels, buckets: defaultBuckets,
		counts: map[string][]uint64{}, sums: map[string]float64{}, totals: map[string]uint64{}}
	registry.add(h)
	return h
}

func (h *histogramVec) Observe(v float64, lv ...string) {
	k := labelKey(h.labels, lv)
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.counts[k]; !ok {
		h.counts[k] = make([]uint64, len(h.buckets))
	}
	for i, b := range h.buckets {
		if v <= b {
			h.counts[k][i]++
		}
	}
	h.sums[k] += v
	h.totals[k]++
}

func (h *histogramVec) write(sb *strings.Builder) {
	h.mu.Lock()
	defer h.mu.Unlock()
	fmt.Fprintf(sb, "# HELP %s %s\n# TYPE %s histogram\n", h.name, h.help, h.name)
	for _, k := range sortedKeys(h.sums) {
		for i, b := range h.buckets {
			fmt.Fprintf(sb, "%s_bucket{%s,le=\"%g\"} %d\n", h.name, k, b, h.counts[k][i])
		}
		fmt.Fprintf(sb, "%s_bucket{%s,le=\"+Inf\"} %d\n", h.name, k, h.totals[k])
		fmt.Fprintf(sb, "%s_sum{%s} %g\n%s_count{%s} %d\n", h.name, k, h.sums[k], h.name, k, h.totals[k])
	}
}

type collector interface{ write(*strings.Builder) }

type metricRegistry struct {
	mu         sync.Mutex
	collectors []collector
}

var registry = &metricRegistry{}

func (r *metricRegistry) add(c collector) {
	r.mu.Lock()
	r.collectors = append(r.collectors, c)
	r.mu.Unlock()
}

func metricsHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		var sb strings.Builder
		registry.mu.Lock()
		for _, c := range registry.collectors {
			c.write(&sb)
		}
		registry.mu.Unlock()
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		_, _ = w.Write([]byte(sb.String()))
	})
}

func labelKey(names, values []string) string {
	parts := make([]string, len(names))
	for i, n := range names {
		v := ""
		if i < len(values) {
			v = strings.ReplaceAll(values[i], `"`, `\"`)
		}
		parts[i] = fmt.Sprintf("%s=%q", n, v)
	}
	return strings.Join(parts, ",")
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
