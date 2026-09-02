package framework

import (
	"fmt"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// NewClientset builds a Kubernetes client bound to an explicit context. It
// never falls back to the loading rules' current-context: contextName must
// be non-empty, and BuildConfigFromKubeconfigGetter-style implicit
// defaulting is deliberately not used here.
func NewClientset(kubeconfigPath, contextName string) (kubernetes.Interface, *rest.Config, error) {
	if contextName == "" {
		return nil, nil, fmt.Errorf("framework: contextName must not be empty")
	}

	loadingRules := clientcmd.NewDefaultClientConfigLoadingRules()
	if kubeconfigPath != "" {
		loadingRules.ExplicitPath = kubeconfigPath
	}

	restConfig, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		loadingRules,
		&clientcmd.ConfigOverrides{CurrentContext: contextName},
	).ClientConfig()
	if err != nil {
		return nil, nil, fmt.Errorf("framework: building config for context %q: %w", contextName, err)
	}

	clientset, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("framework: building clientset: %w", err)
	}

	return clientset, restConfig, nil
}
