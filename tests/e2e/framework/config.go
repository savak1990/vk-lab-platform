// Package framework provides the black-box E2E test suite's shared plumbing:
// explicit cluster selection, the Environment abstraction, and diagnostics.
package framework

import (
	"crypto/tls"
	"flag"
	"fmt"
	"net/http"
	"os"
)

// Config holds the flags a suite run needs. Context has no default: a run
// must never silently fall back to whatever kubeconfig context happens to
// be current, since that could point the suite at an unrelated cluster.
type Config struct {
	Context               string
	KubeconfigPath        string
	InsecureSkipTLSVerify bool
}

// ParseFlags registers and parses the suite's flags, exiting with a clear
// message if a required one is missing. Ginkgo forwards test binary args
// after `-args`, so these are ordinary stdlib flags.
func ParseFlags() *Config {
	cfg := &Config{}
	flag.StringVar(&cfg.Context, "context", "", "kubeconfig context to run against (required)")
	flag.StringVar(&cfg.KubeconfigPath, "kubeconfig", os.Getenv("KUBECONFIG"), "path to kubeconfig (defaults to $KUBECONFIG)")
	flag.BoolVar(&cfg.InsecureSkipTLSVerify, "insecure-skip-tls-verify", false,
		"skip TLS chain verification for HTTPS service checks (needed against a civo cluster on the Let's Encrypt staging issuer, CIVO-070)")
	flag.Parse()

	if cfg.Context == "" {
		fmt.Fprintln(os.Stderr, "framework: --context is required (refusing to fall back to the current kubeconfig context)")
		os.Exit(1)
	}
	return cfg
}

// HTTPClient returns the client every service check should use to reach a
// ServiceURL. AWS's ACM certificate and civo's prod Let's Encrypt issuer
// both verify normally; only a civo cluster left on the staging issuer
// needs InsecureSkipTLSVerify, since staging's root is deliberately
// untrusted everywhere.
func (c *Config) HTTPClient() *http.Client {
	if !c.InsecureSkipTLSVerify {
		return http.DefaultClient
	}
	return &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // opt-in via flag, staging-issuer testing only
		},
	}
}
