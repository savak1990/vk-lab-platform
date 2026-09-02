package framework

import (
	"context"
	"fmt"
	"net/url"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	envoyGatewayNamespace = "argocd"
	grafanaNamespace      = "observability"
	postgresNamespace     = "cnpg-system"
)

// Environment abstracts *how* a test reaches a service, so service test
// files can express assertions once and run unmodified against a kind
// cluster or a real EKS cluster. Only AWSEnvironment exists today; a kind
// implementation is expected later (spec 024, blocked on `make kind-up`
// not existing yet) and should satisfy this same interface without any
// call site needing to branch on which one is in use.
type Environment interface {
	KubernetesClient() kubernetes.Interface
	ServiceURL(service string) string
	PostgresDSN(cluster string) string
	Close()
}

// AWSEnvironment reaches services via their public HTTPRoute hostname
// (Grafana, Argo CD) or via a port-forward to their ClusterIP Service
// (Postgres, which has no external endpoint).
type AWSEnvironment struct {
	clientset    kubernetes.Interface
	dynamic      dynamic.Interface
	restConfig   *rest.Config
	portForwards []chan struct{}
}

// Close stops every port-forward opened by PostgresDSN. Call once from
// AfterSuite - each forward otherwise leaks its goroutine and SPDY
// connection for the life of the test binary.
func (e *AWSEnvironment) Close() {
	for _, stopCh := range e.portForwards {
		close(stopCh)
	}
}

func NewAWSEnvironment(clientset kubernetes.Interface, dynamicClient dynamic.Interface, restConfig *rest.Config) *AWSEnvironment {
	return &AWSEnvironment{clientset: clientset, dynamic: dynamicClient, restConfig: restConfig}
}

func (e *AWSEnvironment) KubernetesClient() kubernetes.Interface {
	return e.clientset
}

// ServiceURL resolves "grafana" or "argocd" to their public HTTPS hostname
// via the Gateway API HTTPRoute Argo CD already manages for them.
func (e *AWSEnvironment) ServiceURL(service string) string {
	ns, ok := map[string]string{
		"grafana": grafanaNamespace,
		"argocd":  envoyGatewayNamespace,
	}[service]
	if !ok {
		panic(fmt.Sprintf("framework: unknown service %q", service))
	}

	hostname, err := ResolveHTTPRouteHostname(context.Background(), e.dynamic, ns, service)
	if err != nil {
		panic(fmt.Sprintf("framework: resolving %s URL: %v", service, err))
	}
	return "https://" + hostname
}

// PostgresDSN opens a port-forward to the named CNPG cluster's primary
// (via its "<cluster>-rw" Service) and returns a DSN using the in-cluster
// "<cluster>-app" Secret's credentials — reading the Secret rather than SSM
// directly, so the check also proves External Secrets Operator synced it.
func (e *AWSEnvironment) PostgresDSN(cluster string) string {
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

	localPort, stopCh, err := PortForward(e.restConfig, e.clientset, postgresNamespace, podName, 5432)
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
