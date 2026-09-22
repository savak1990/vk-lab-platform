package framework

import (
	"context"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/intstr"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/kubernetes/fake"
)

func route(namespace, name string, hostnames []string, pathValue string) *unstructured.Unstructured {
	spec := map[string]any{
		"rules": []any{map[string]any{
			"matches": []any{map[string]any{
				"path": map[string]any{"type": "PathPrefix", "value": pathValue},
			}},
		}},
	}
	if len(hostnames) > 0 {
		hosts := make([]any, 0, len(hostnames))
		for _, h := range hostnames {
			hosts = append(hosts, h)
		}
		spec["hostnames"] = hosts
	}
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "gateway.networking.k8s.io/v1",
		"kind":       "HTTPRoute",
		"metadata":   map[string]any{"namespace": namespace, "name": name},
		"spec":       spec,
	}}
}

func dynamicFor(objects ...runtime.Object) *dynamicfake.FakeDynamicClient {
	scheme := runtime.NewScheme()
	scheme.AddKnownTypeWithName(httpRouteGVR.GroupVersion().WithKind("HTTPRouteList"), &unstructured.UnstructuredList{})
	return dynamicfake.NewSimpleDynamicClientWithCustomListKinds(scheme,
		map[schema.GroupVersionResource]string{httpRouteGVR: "HTTPRouteList"}, objects...)
}

func TestResolveHTTPRouteHostnameWins(t *testing.T) {
	client := dynamicFor(route("observability", "grafana", []string{"grafana.example.com"}, "/grafana"))

	hostname, prefix, err := ResolveHTTPRoute(context.Background(), client, "observability", "grafana")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if hostname != "grafana.example.com" {
		t.Errorf("hostname = %q, want grafana.example.com", hostname)
	}
	if prefix != "" {
		t.Errorf("prefix = %q, want empty when a hostname exists", prefix)
	}
}

func TestResolveHTTPRouteFallsBackToPathPrefix(t *testing.T) {
	client := dynamicFor(route("observability", "grafana", nil, "/grafana"))

	hostname, prefix, err := ResolveHTTPRoute(context.Background(), client, "observability", "grafana")
	if err != nil {
		t.Fatalf("a route without hostnames must not be an error, got: %v", err)
	}
	if hostname != "" {
		t.Errorf("hostname = %q, want empty", hostname)
	}
	if prefix != "/grafana" {
		t.Errorf("prefix = %q, want /grafana", prefix)
	}
}

// Argo CD owns "/" on the target with no hostname, and callers append their
// own path to what ServiceURL returns, so the prefix must not carry one too.
func TestRootPrefixTrimsToEmpty(t *testing.T) {
	client := dynamicFor(route("argocd", "argocd", nil, "/"))

	_, prefix, err := ResolveHTTPRoute(context.Background(), client, "argocd", "argocd")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := strings.TrimSuffix(prefix, "/") + "/healthz"; got != "/healthz" {
		t.Errorf("got %q, want /healthz", got)
	}
}

func TestResolveHTTPRouteMissingRouteIsAnError(t *testing.T) {
	client := dynamicFor()

	if _, _, err := ResolveHTTPRoute(context.Background(), client, "argocd", "argocd"); err == nil {
		t.Fatal("a missing route must be an error, not an empty hostname")
	}
}

func gatewaySvc(targetPort intstr.IntOrString) *corev1.Service {
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "envoy-envoy-platform-gateway-6f2a1b",
			Namespace: "envoy",
			Labels:    map[string]string{"gateway.envoyproxy.io/owning-gateway-name": "platform-gateway"},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": "envoy"},
			Ports:    []corev1.ServicePort{{Port: 80, TargetPort: targetPort}},
		},
	}
}

// A port-forward addresses a pod, so the Service's port 80 must be translated
// to the container's own port before it is used.
func TestGatewayServicePortReturnsTargetPort(t *testing.T) {
	client := fake.NewSimpleClientset(gatewaySvc(intstr.FromInt(10080)))

	selector, port, err := GatewayServicePort(context.Background(), client, "envoy", "platform-gateway", 80)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if port != 10080 {
		t.Errorf("port = %d, want the targetPort 10080, not the Service port", port)
	}
	if selector.String() != "app=envoy" {
		t.Errorf("selector = %q, want app=envoy", selector)
	}
}

func TestGatewayServicePortRejectsNamedTargetPort(t *testing.T) {
	client := fake.NewSimpleClientset(gatewaySvc(intstr.FromString("http")))

	if _, _, err := GatewayServicePort(context.Background(), client, "envoy", "platform-gateway", 80); err == nil {
		t.Fatal("a named targetPort must fail loudly, not be guessed at")
	}
}

func TestGatewayServicePortNoService(t *testing.T) {
	client := fake.NewSimpleClientset()

	if _, _, err := GatewayServicePort(context.Background(), client, "envoy", "platform-gateway", 80); err == nil {
		t.Fatal("no gateway Service must be an error")
	}
}
