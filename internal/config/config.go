package config

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Duration is a custom type that wraps time.Duration for YAML unmarshaling
type Duration time.Duration

// Config represents the complete configuration for Klaviger
type Config struct {
	Server         ServerConfig         `yaml:"server"`
	ReverseProxy   ReverseProxyConfig   `yaml:"reverseProxy"`
	ForwardProxy   ForwardProxyConfig   `yaml:"forwardProxy"`
	Observability  ObservabilityConfig  `yaml:"observability"`
}

// ServerConfig holds server-level configuration
type ServerConfig struct {
	ReverseProxyPort int             `yaml:"reverseProxyPort"`
	ReverseProxyBind string          `yaml:"reverseProxyBind"`
	ForwardProxyPort int             `yaml:"forwardProxyPort"`
	ForwardProxyBind string          `yaml:"forwardProxyBind"`
	ReadTimeout      Duration        `yaml:"readTimeout"`
	WriteTimeout     Duration        `yaml:"writeTimeout"`
	TLS              TLSConfig       `yaml:"tls"`
	ClientTLS        ClientTLSConfig `yaml:"clientTls"`
	SPIFFE           *SPIFFEConfig   `yaml:"spiffe,omitempty"`
}

// TLSConfig holds TLS configuration
type TLSConfig struct {
	Enabled  bool          `yaml:"enabled"`
	CertFile string        `yaml:"certFile"`
	KeyFile  string        `yaml:"keyFile"`
	SPIFFE   *SPIFFEConfig `yaml:"spiffe,omitempty"`
}

// ClientTLSConfig holds client-side TLS configuration
type ClientTLSConfig struct {
	Enabled            bool          `yaml:"enabled"`
	CertFile           string        `yaml:"certFile"`
	KeyFile            string        `yaml:"keyFile"`
	CAFile             string        `yaml:"caFile"`
	SPIFFE             *SPIFFEConfig `yaml:"spiffe,omitempty"`
	InsecureSkipVerify bool          `yaml:"insecureSkipVerify"`
}

// SPIFFEConfig holds SPIFFE Workload API configuration
type SPIFFEConfig struct {
	Enabled           bool     `yaml:"enabled"`
	SocketPath        string   `yaml:"socketPath"`
	TrustDomain       string   `yaml:"trustDomain,omitempty"`
	AcceptedSPIFFEIDs []string `yaml:"acceptedSpiffeIds,omitempty"`
	JWTAudience       []string `yaml:"jwtAudience,omitempty"`
}

// ReverseProxyConfig holds reverse proxy configuration
type ReverseProxyConfig struct {
	Backend      string             `yaml:"backend"`
	Verification VerificationConfig `yaml:"verification"`
	PublicPaths  []string           `yaml:"publicPaths,omitempty"` // Paths that bypass authentication (e.g., /.well-known/, /api/login)
}

// VerificationConfig holds token verification configuration
type VerificationConfig struct {
	Mode           string                  `yaml:"mode"` // jwt | introspection | k8s
	JWT            *JWTConfig              `yaml:"jwt,omitempty"`
	Introspection  *IntrospectionConfig    `yaml:"introspection,omitempty"`
	Kubernetes     *KubernetesConfig       `yaml:"kubernetes,omitempty"`
}

// JWTConfig holds JWT verification configuration
type JWTConfig struct {
	JWKSUrl         string   `yaml:"jwksUrl"`
	Issuer          string   `yaml:"issuer"`
	Audience        string   `yaml:"audience"`
	RequiredScopes  []string `yaml:"requiredScopes"`
	CacheTTL        Duration `yaml:"cacheTtl"`
	BearerTokenFile string   `yaml:"bearerTokenFile"`
	CAFile          string   `yaml:"caFile"`
}

// IntrospectionConfig holds token introspection configuration
type IntrospectionConfig struct {
	Endpoint     string `yaml:"endpoint"`
	ClientID     string `yaml:"clientId"`
	ClientSecret string `yaml:"clientSecret"`
}

// KubernetesConfig holds Kubernetes verification configuration
type KubernetesConfig struct {
	Verb      string `yaml:"verb"`
	Resource  string `yaml:"resource"`
	APIGroup  string `yaml:"apiGroup"`
	Namespace string `yaml:"namespace"`
}

// ForwardProxyConfig holds forward proxy configuration
type ForwardProxyConfig struct {
	DefaultMode InjectionMode `yaml:"defaultMode"`
	HostRules   []HostRule    `yaml:"hostRules"`
}

// HostRule defines token injection for a specific host pattern
type HostRule struct {
	HostPattern string        `yaml:"hostPattern"`
	Mode        InjectionMode `yaml:"mode"`
}

// InjectionMode defines how tokens are injected
type InjectionMode struct {
	Type  string       `yaml:"type"` // passthrough | file | oauth | vault
	File  *FileConfig  `yaml:"file,omitempty"`
	OAuth *OAuthConfig `yaml:"oauth,omitempty"`
	Vault *VaultConfig `yaml:"vault,omitempty"`
}

// FileConfig holds file-based token injection configuration
type FileConfig struct {
	Path            string   `yaml:"path"`
	RefreshInterval Duration `yaml:"refreshInterval"`
}

// OAuthConfig holds OAuth token exchange configuration
type OAuthConfig struct {
	TokenURL         string   `yaml:"tokenUrl"`
	Audience         string   `yaml:"audience"`
	Scope            string   `yaml:"scope"`
	CacheTTL         Duration `yaml:"cacheTtl"`
	ClientTokenPath  string   `yaml:"clientTokenPath,omitempty"`  // Path to client token for OAuth authentication (default: /var/run/secrets/kubernetes.io/serviceaccount/token)
	ClientAuthMethod string   `yaml:"clientAuthMethod,omitempty"` // How to present client token: "header" or "assertion" (default: "header")
	IncludeActorToken *bool   `yaml:"includeActorToken,omitempty"` // Send authentication token as actor_token in request body per RFC 8693 (default: true)
}

// VaultConfig holds Vault token injection configuration
type VaultConfig struct {
	Address    string   `yaml:"address"`
	Path       string   `yaml:"path"`
	Field      string   `yaml:"field"`
	AuthMethod string   `yaml:"authMethod"` // kubernetes | token
	Role       string   `yaml:"role"`
	Token      string   `yaml:"token"`
	CacheTTL   Duration `yaml:"cacheTtl"`
}

// ObservabilityConfig holds observability configuration
type ObservabilityConfig struct {
	Metrics MetricsConfig `yaml:"metrics"`
	Tracing TracingConfig `yaml:"tracing"`
	Logging LoggingConfig `yaml:"logging"`
}

// MetricsConfig holds Prometheus metrics configuration
type MetricsConfig struct {
	Enabled bool   `yaml:"enabled"`
	Port    int    `yaml:"port"`
	Path    string `yaml:"path"`
}

// TracingConfig holds OpenTelemetry tracing configuration
type TracingConfig struct {
	Enabled     bool   `yaml:"enabled"`
	Endpoint    string `yaml:"endpoint"`
	ServiceName string `yaml:"serviceName"`
}

// LoggingConfig holds logging configuration
type LoggingConfig struct {
	Level  string `yaml:"level"`  // debug | info | warn | error
	Format string `yaml:"format"` // json | console
}

// envVarPattern matches ${VAR_NAME} patterns
var envVarPattern = regexp.MustCompile(`\$\{([^}]+)\}`)

// Load reads and parses the configuration file
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	// Expand environment variables
	expanded := expandEnvVars(string(data))

	var cfg Config
	if err := yaml.Unmarshal([]byte(expanded), &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	// Set defaults
	setDefaults(&cfg)

	// Validate configuration
	if err := Validate(&cfg); err != nil {
		return nil, fmt.Errorf("invalid configuration: %w", err)
	}

	return &cfg, nil
}

// expandEnvVars replaces ${VAR_NAME} with environment variable values
func expandEnvVars(input string) string {
	return envVarPattern.ReplaceAllStringFunc(input, func(match string) string {
		// Extract variable name (remove ${ and })
		varName := match[2 : len(match)-1]
		value := os.Getenv(varName)
		if value == "" {
			// Keep original if env var not set
			return match
		}
		return value
	})
}

// setDefaults sets default values for optional configuration
func setDefaults(cfg *Config) {
	// Server defaults
	if cfg.Server.ReverseProxyPort == 0 {
		cfg.Server.ReverseProxyPort = 8080
	}
	if cfg.Server.ReverseProxyBind == "" {
		cfg.Server.ReverseProxyBind = "0.0.0.0"
	}
	if cfg.Server.ForwardProxyPort == 0 {
		cfg.Server.ForwardProxyPort = 8081
	}
	if cfg.Server.ForwardProxyBind == "" {
		cfg.Server.ForwardProxyBind = "0.0.0.0"
	}
	if cfg.Server.ReadTimeout == 0 {
		cfg.Server.ReadTimeout = Duration(30 * time.Second)
	}
	if cfg.Server.WriteTimeout == 0 {
		cfg.Server.WriteTimeout = Duration(30 * time.Second)
	}

	// SPIFFE defaults
	if cfg.Server.SPIFFE != nil && cfg.Server.SPIFFE.SocketPath == "" {
		cfg.Server.SPIFFE.SocketPath = "unix:///run/spire/sockets/agent.sock"
	}
	if cfg.Server.TLS.SPIFFE != nil && cfg.Server.TLS.SPIFFE.SocketPath == "" {
		cfg.Server.TLS.SPIFFE.SocketPath = "unix:///run/spire/sockets/agent.sock"
	}
	if cfg.Server.ClientTLS.SPIFFE != nil && cfg.Server.ClientTLS.SPIFFE.SocketPath == "" {
		cfg.Server.ClientTLS.SPIFFE.SocketPath = "unix:///run/spire/sockets/agent.sock"
	}

	// JWT defaults
	if cfg.ReverseProxy.Verification.JWT != nil {
		if cfg.ReverseProxy.Verification.JWT.CacheTTL == 0 {
			cfg.ReverseProxy.Verification.JWT.CacheTTL = Duration(5 * time.Minute)
		}
	}

	// File injection defaults
	for i := range cfg.ForwardProxy.HostRules {
		if cfg.ForwardProxy.HostRules[i].Mode.File != nil {
			if cfg.ForwardProxy.HostRules[i].Mode.File.RefreshInterval == 0 {
				cfg.ForwardProxy.HostRules[i].Mode.File.RefreshInterval = Duration(1 * time.Minute)
			}
		}
	}

	// OAuth defaults
	for i := range cfg.ForwardProxy.HostRules {
		if cfg.ForwardProxy.HostRules[i].Mode.OAuth != nil {
			if cfg.ForwardProxy.HostRules[i].Mode.OAuth.CacheTTL == 0 {
				cfg.ForwardProxy.HostRules[i].Mode.OAuth.CacheTTL = Duration(10 * time.Minute)
			}
			if cfg.ForwardProxy.HostRules[i].Mode.OAuth.IncludeActorToken == nil {
				trueVal := true
				cfg.ForwardProxy.HostRules[i].Mode.OAuth.IncludeActorToken = &trueVal
			}
		}
	}

	// Vault defaults
	for i := range cfg.ForwardProxy.HostRules {
		if cfg.ForwardProxy.HostRules[i].Mode.Vault != nil {
			if cfg.ForwardProxy.HostRules[i].Mode.Vault.CacheTTL == 0 {
				cfg.ForwardProxy.HostRules[i].Mode.Vault.CacheTTL = Duration(5 * time.Minute)
			}
			if cfg.ForwardProxy.HostRules[i].Mode.Vault.Field == "" {
				cfg.ForwardProxy.HostRules[i].Mode.Vault.Field = "token"
			}
		}
	}

	// Observability defaults
	if cfg.Observability.Metrics.Port == 0 {
		cfg.Observability.Metrics.Port = 9090
	}
	if cfg.Observability.Metrics.Path == "" {
		cfg.Observability.Metrics.Path = "/metrics"
	}
	if cfg.Observability.Logging.Level == "" {
		cfg.Observability.Logging.Level = "info"
	}
	if cfg.Observability.Logging.Format == "" {
		cfg.Observability.Logging.Format = "json"
	}
	if cfg.Observability.Tracing.ServiceName == "" {
		cfg.Observability.Tracing.ServiceName = "klaviger"
	}
}

// UnmarshalYAML implements custom unmarshaling for Duration
func (d *Duration) UnmarshalYAML(node *yaml.Node) error {
	var s string
	if err := node.Decode(&s); err != nil {
		return err
	}
	parsed, err := time.ParseDuration(s)
	if err != nil {
		return fmt.Errorf("invalid duration: %w", err)
	}
	*d = Duration(parsed)
	return nil
}

// MarshalYAML implements custom marshaling for Duration
func (d Duration) MarshalYAML() (interface{}, error) {
	return time.Duration(d).String(), nil
}

// Sanitize returns a copy of the config with secrets redacted
func (cfg *Config) Sanitize() *Config {
	sanitized := *cfg

	// Sanitize reverse proxy verification
	if sanitized.ReverseProxy.Verification.Introspection != nil {
		introspection := *sanitized.ReverseProxy.Verification.Introspection
		introspection.ClientSecret = redactSecret(introspection.ClientSecret)
		sanitized.ReverseProxy.Verification.Introspection = &introspection
	}

	// Sanitize forward proxy injection modes
	for i := range sanitized.ForwardProxy.HostRules {
		if sanitized.ForwardProxy.HostRules[i].Mode.Vault != nil {
			vault := *sanitized.ForwardProxy.HostRules[i].Mode.Vault
			vault.Token = redactSecret(vault.Token)
			sanitized.ForwardProxy.HostRules[i].Mode.Vault = &vault
		}
	}

	return &sanitized
}

// redactSecret redacts a secret value
func redactSecret(s string) string {
	if s == "" {
		return ""
	}
	if strings.HasPrefix(s, "${") && strings.HasSuffix(s, "}") {
		// Keep env var references visible
		return s
	}
	return "***REDACTED***"
}
