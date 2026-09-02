// Package framework provides the black-box E2E test suite's shared plumbing:
// explicit cluster selection, the Environment abstraction, and diagnostics.
package framework

import (
	"flag"
	"fmt"
	"os"
)

// Config holds the flags a suite run needs. Context has no default: a run
// must never silently fall back to whatever kubeconfig context happens to
// be current, since that could point the suite at an unrelated cluster.
type Config struct {
	Context        string
	KubeconfigPath string
}

// ParseFlags registers and parses the suite's flags, exiting with a clear
// message if a required one is missing. Ginkgo forwards test binary args
// after `-args`, so these are ordinary stdlib flags.
func ParseFlags() *Config {
	cfg := &Config{}
	flag.StringVar(&cfg.Context, "context", "", "kubeconfig context to run against (required)")
	flag.StringVar(&cfg.KubeconfigPath, "kubeconfig", os.Getenv("KUBECONFIG"), "path to kubeconfig (defaults to $KUBECONFIG)")
	flag.Parse()

	if cfg.Context == "" {
		fmt.Fprintln(os.Stderr, "framework: --context is required (refusing to fall back to the current kubeconfig context)")
		os.Exit(1)
	}
	return cfg
}
