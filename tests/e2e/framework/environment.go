package framework

import (
	"context"
	"fmt"
	"net/url"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	argocdNamespace   = "argocd"
	grafanaNamespace  = "observability"
	postgresNamespace = "cnpg-system"
	envoyNamespace    = "envoy"
	gatewayName       = "platform-gateway"
)

// Environment abstracts *how* a test reaches a service, so service test
// files can express assertions once and run unmodified against a kind
// cluster or a real EKS/Civo cluster. One implementation serves both: it
// asks the cluster how each service is addressed rather than being told,
// so no call site branches on which kind of cluster it runs against.
type Environment interface {
	KubernetesClient() kubernetes.Interface
	ServiceURL(service string) string
	PostgresDSN(cluster string) string
	Close()
}

// ClusterEnvironment reaches a service by its HTTPRoute hostname where the
// route declares one, and otherwise through a port-forward to the gateway.
// Postgres has no route either way and is always forwarded.
type ClusterEnvironment struct {
	clientset    kubernetes.Interface
	dynamic      dynamic.Interface
	restConfig   *rest.Config
	portForwards []chan struct{}
	gatewayPort  int
}

// Close stops every port-forward this environment opened. Call once from
// AfterSuite - each forward otherwise leaks its goroutine and SPDY
// connection for the life of the test binary.
func (e *ClusterEnvironment) Close() {
	for _, stopCh := range e.portForwards {
		close(stopCh)
	}
}

func NewClusterEnvironment(clientset kubernetes.Interface, dynamicClient dynamic.Interface, restConfig *rest.Config) *ClusterEnvironment {
	return &ClusterEnvironment{clientset: clientset, dynamic: dynamicClient, restConfig: restConfig}
}

func (e *ClusterEnvironment) KubernetesClient() kubernetes.Interface {
	return e.clientset
}

// ServiceURL resolves "grafana" or "argocd" to a base URL, from the Gateway
// API HTTPRoute Argo CD manages for it. A route with a hostname is public
// HTTPS; a route with only a path prefix is reached through the gateway.
func (e *ClusterEnvironment) ServiceURL(service string) string {
	ns, ok := map[string]string{
		"grafana": grafanaNamespace,
		"argocd":  argocdNamespace,
	}[service]
	if !ok {
		panic(fmt.Sprintf("framework: unknown service %q", service))
	}

	hostname, pathPrefix, err := ResolveHTTPRoute(context.Background(), e.dynamic, ns, service)
	if err != nil {
		panic(fmt.Sprintf("framework: resolving %s URL: %v", service, err))
	}
	if hostname != "" {
		return "https://" + hostname
	}

	// Argo CD's prefix is "/", and callers append their own path to this.
	return fmt.Sprintf("http://127.0.0.1:%d%s", e.forwardGateway(), strings.TrimSuffix(pathPrefix, "/"))
}

// forwardGateway opens one port-forward to the Envoy Gateway pod and reuses
// it, so every service without a hostname shares a single tunnel. The local
// port is not pinned: Grafana builds its redirects from the request host and
// its assets from a relative base, so nothing outside the tunnel names it.
func (e *ClusterEnvironment) forwardGateway() int {
	if e.gatewayPort != 0 {
		return e.gatewayPort
	}
	ctx := context.Background()

	selector, targetPort, err := GatewayServicePort(ctx, e.clientset, envoyNamespace, gatewayName, 80)
	if err != nil {
		panic(fmt.Sprintf("framework: resolving the gateway Service: %v", err))
	}
	podName, err := FirstReadyPod(ctx, e.clientset, envoyNamespace, selector)
	if err != nil {
		panic(fmt.Sprintf("framework: finding a ready gateway pod: %v", err))
	}

	bound, stopCh, err := PortForward(e.restConfig, e.clientset, envoyNamespace, podName, targetPort, 0)
	if err != nil {
		panic(fmt.Sprintf("framework: port-forwarding to the gateway: %v", err))
	}
	e.portForwards = append(e.portForwards, stopCh)
	e.gatewayPort = bound
	return bound
}

// PostgresDSN opens a port-forward to the named CNPG cluster's primary
// (via its "<cluster>-rw" Service) and returns a DSN using the in-cluster
// "<cluster>-app" Secret's credentials — reading the Secret rather than SSM
// directly, so the check also proves External Secrets Operator synced it.
func (e *ClusterEnvironment) PostgresDSN(cluster string) string {
	ctx := context.Background()

	secret, err := e.clientset.CoreV1().Secrets(postgresNamespace).Get(ctx, cluster+"-app", metav1.GetOptions{})
	if err != nil {
		panic(fmt.Sprintf("framework: getting %s-app secret: %v", cluster, err))
	}
	username := string(secret.Data["username"])
	password := string(secret.Data["password"])

	selector, err := ServiceSelector(ctx, e.clientset, postgresNamespace, cluster+"-rw")
	if err != nil {
		panic(fmt.Sprintf("framework: resolving %s-rw selector: %v", cluster, err))
	}
	podName, err := FirstReadyPod(ctx, e.clientset, postgresNamespace, selector)
	if err != nil {
		panic(fmt.Sprintf("framework: finding ready pod for %s-rw: %v", cluster, err))
	}

	localPort, stopCh, err := PortForward(e.restConfig, e.clientset, postgresNamespace, podName, 5432, 0)
	if err != nil {
		panic(fmt.Sprintf("framework: port-forwarding to %s: %v", podName, err))
	}
	e.portForwards = append(e.portForwards, stopCh)

	dsn := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(username, password),
		Host:     fmt.Sprintf("127.0.0.1:%d", localPort),
		Path:     "/vkdb",
		RawQuery: "sslmode=require",
	}
	return dsn.String()
}
