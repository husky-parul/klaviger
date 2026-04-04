package reverseproxy

import (
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"

	"github.com/grs/klaviger/internal/auth"
	"github.com/grs/klaviger/internal/config"
	"github.com/grs/klaviger/internal/observability"
	"github.com/grs/klaviger/internal/server"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.uber.org/zap"
)

// Proxy is the reverse proxy with authentication
type Proxy struct {
	proxy       *httputil.ReverseProxy
	backend     string
	verifier    auth.Verifier
	logger      *zap.Logger
	publicPaths []string
}

// New creates a new reverse proxy
func New(cfg *config.ReverseProxyConfig, verifier auth.Verifier, logger *zap.Logger) (*Proxy, error) {
	backendURL, err := url.Parse(cfg.Backend)
	if err != nil {
		return nil, err
	}

	proxy := httputil.NewSingleHostReverseProxy(backendURL)

	// Customize director to preserve original request
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		// Add custom headers if needed
		req.Header.Set("X-Forwarded-Host", req.Host)
		req.Header.Set("X-Forwarded-Proto", req.URL.Scheme)

		// Add claims as headers (optional)
		if claims, ok := GetClaimsFromContext(req.Context()); ok {
			req.Header.Set("X-Token-Subject", claims.Subject)
			req.Header.Set("X-Token-Issuer", claims.Issuer)
		}
	}

	// Customize error handler
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		logger.Error("reverse proxy error",
			zap.Error(err),
			zap.String("backend", backendURL.String()),
			zap.String("path", r.URL.Path),
		)
		observability.ReverseProxyRequestsTotal.WithLabelValues("502").Inc()
		w.WriteHeader(http.StatusBadGateway)
		w.Write([]byte("Backend error\n"))
	}

	return &Proxy{
		proxy:       proxy,
		backend:     cfg.Backend,
		verifier:    verifier,
		logger:      logger.With(zap.String("component", "reverse_proxy")),
		publicPaths: cfg.PublicPaths,
	}, nil
}

// Handler returns the HTTP handler with authentication middleware
func (p *Proxy) Handler() http.Handler {
	mux := http.NewServeMux()

	// Health endpoints (no auth required)
	mux.Handle("/health/", server.HealthHandler())

	// Public paths (no auth required) — configurable via reverseProxy.publicPaths
	passthrough := proxyPassthrough(p)
	for _, path := range p.publicPaths {
		p.logger.Info("registering public path (no auth)", zap.String("path", path))
		mux.Handle(path, passthrough)
	}

	// Proxy handler with metrics, authentication, and tracing
	proxyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Start tracing span
		tracer := otel.Tracer("reverse-proxy")
		ctx, span := tracer.Start(r.Context(), "reverse-proxy-request")
		defer span.End()

		// Add attributes to span
		span.SetAttributes(
			attribute.String("http.method", r.Method),
			attribute.String("http.url", r.URL.Path),
			attribute.String("http.host", r.Host),
		)

		start := time.Now()

		// Create a response writer that captures the status code
		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		// Forward request to backend with traced context
		r = r.WithContext(ctx)
		p.proxy.ServeHTTP(rw, r)

		// Record metrics
		duration := time.Since(start)
		status := http.StatusText(rw.statusCode)
		observability.ReverseProxyRequestsTotal.WithLabelValues(status).Inc()
		observability.ReverseProxyRequestDuration.WithLabelValues(status).Observe(duration.Seconds())

		// Add status to span
		span.SetAttributes(attribute.Int("http.status_code", rw.statusCode))
		if rw.statusCode >= 400 {
			span.SetStatus(codes.Error, fmt.Sprintf("HTTP %d", rw.statusCode))
		}

		p.logger.Debug("request processed",
			zap.String("method", r.Method),
			zap.String("path", r.URL.Path),
			zap.Int("status", rw.statusCode),
			zap.Duration("duration", duration),
		)
	})

	// Apply authentication middleware to all non-health endpoints
	authHandler := AuthMiddleware(p.verifier, p.logger)(proxyHandler)

	mux.Handle("/", authHandler)

	return mux
}

// proxyPassthrough returns a handler that forwards requests to the backend without authentication.
func proxyPassthrough(p *Proxy) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.proxy.ServeHTTP(w, r)
	})
}

// responseWriter wraps http.ResponseWriter to capture status code
type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}
