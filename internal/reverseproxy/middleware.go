package reverseproxy

import (
	"context"
	"net/http"
	"strings"

	"github.com/grs/klaviger/internal/auth"
	"github.com/grs/klaviger/internal/observability"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.uber.org/zap"
)

// contextKey is a custom type for context keys to avoid collisions
type contextKey string

const (
	// ClaimsContextKey is the context key for storing verified claims
	ClaimsContextKey contextKey = "claims"
)

// AuthMiddleware creates middleware that verifies tokens
func AuthMiddleware(verifier auth.Verifier, logger *zap.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Start tracing span
			tracer := otel.Tracer("reverse-proxy")
			ctx, span := tracer.Start(r.Context(), "auth-middleware")
			defer span.End()

			// Allow CORS preflight requests through without auth
			if r.Method == http.MethodOptions {
				next.ServeHTTP(w, r)
				return
			}

			// Extract token from Authorization header
			authHeader := r.Header.Get("Authorization")
			if authHeader == "" {
				span.SetStatus(codes.Error, "missing authorization header")
				logger.Debug("missing authorization header",
					zap.String("path", r.URL.Path),
					zap.String("method", r.Method),
				)
				observability.ReverseProxyRequestsTotal.WithLabelValues("401").Inc()
				w.WriteHeader(http.StatusUnauthorized)
				w.Write([]byte("Missing authorization header\n"))
				return
			}

			// Check Bearer prefix
			parts := strings.SplitN(authHeader, " ", 2)
			if len(parts) != 2 || strings.ToLower(parts[0]) != "bearer" {
				span.SetStatus(codes.Error, "invalid authorization header format")
				logger.Debug("invalid authorization header format",
					zap.String("path", r.URL.Path),
				)
				observability.ReverseProxyRequestsTotal.WithLabelValues("401").Inc()
				w.WriteHeader(http.StatusUnauthorized)
				w.Write([]byte("Invalid authorization header format\n"))
				return
			}

			token := parts[1]

			// Verify token (pass context for trace propagation)
			claims, err := verifier.Verify(ctx, token)
			if err != nil {
				span.SetStatus(codes.Error, "token verification failed")
				span.RecordError(err)
				logger.Debug("token verification failed",
					zap.Error(err),
					zap.String("path", r.URL.Path),
				)
				observability.ReverseProxyRequestsTotal.WithLabelValues("401").Inc()
				w.WriteHeader(http.StatusUnauthorized)
				w.Write([]byte("Token verification failed\n"))
				return
			}

			// Add claims to span
			span.SetAttributes(
				attribute.String("auth.subject", claims.Subject),
				attribute.String("auth.issuer", claims.Issuer),
			)

			// Add claims to context
			ctx = context.WithValue(ctx, ClaimsContextKey, claims)
			r = r.WithContext(ctx)

			// Call next handler
			next.ServeHTTP(w, r)
		})
	}
}

// GetClaimsFromContext retrieves claims from the request context
func GetClaimsFromContext(ctx context.Context) (*auth.Claims, bool) {
	claims, ok := ctx.Value(ClaimsContextKey).(*auth.Claims)
	return claims, ok
}
