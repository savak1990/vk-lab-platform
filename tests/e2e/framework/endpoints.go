package framework

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
)

var httpRouteGVR = schema.GroupVersionResource{
	Group:    "gateway.networking.k8s.io",
	Version:  "v1",
	Resource: "httproutes",
}

// ResolveHTTPRoute reads how an HTTPRoute is addressed: its first hostname,
// or, for a route that declares none, the path prefix it matches. A route
// without a hostname is reachable only through the gateway, so an empty
// hostname is an answer rather than an error.
func ResolveHTTPRoute(ctx context.Context, dynamicClient dynamic.Interface, namespace, name string) (hostname, pathPrefix string, err error) {
	route, err := dynamicClient.Resource(httpRouteGVR).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return "", "", fmt.Errorf("framework: getting HTTPRoute %s/%s: %w", namespace, name, err)
	}

	hostnames, found, err := unstructured.NestedStringSlice(route.Object, "spec", "hostnames")
	if err == nil && found && len(hostnames) > 0 {
		return hostnames[0], "", nil
	}

	prefix, err := firstRulePathPrefix(route.Object)
	if err != nil {
		return "", "", fmt.Errorf("framework: HTTPRoute %s/%s has neither spec.hostnames nor a path match: %w", namespace, name, err)
	}
	return "", prefix, nil
}

// firstRulePathPrefix reads spec.rules[0].matches[0].path.value. NestedString
// cannot index a slice, so the two levels are walked by hand.
func firstRulePathPrefix(obj map[string]any) (string, error) {
	rules, found, err := unstructured.NestedSlice(obj, "spec", "rules")
	if err != nil || !found || len(rules) == 0 {
		return "", fmt.Errorf("no spec.rules")
	}
	rule, ok := rules[0].(map[string]any)
	if !ok {
		return "", fmt.Errorf("spec.rules[0] is not an object")
	}
	matches, found, err := unstructured.NestedSlice(rule, "matches")
	if err != nil || !found || len(matches) == 0 {
		return "", fmt.Errorf("no spec.rules[0].matches")
	}
	match, ok := matches[0].(map[string]any)
	if !ok {
		return "", fmt.Errorf("spec.rules[0].matches[0] is not an object")
	}
	value, found, err := unstructured.NestedString(match, "path", "value")
	if err != nil || !found || value == "" {
		return "", fmt.Errorf("no spec.rules[0].matches[0].path.value")
	}
	return value, nil
}

// GatewayServicePort finds the Envoy Gateway Service by the label its
// controller sets, and returns a selector for its pods plus the port those
// pods listen on. The Service name carries a hash, so it cannot be named;
// and a port-forward addresses a pod, so the Service's own port 80 would
// never be translated to the container's port for us.
func GatewayServicePort(ctx context.Context, clientset kubernetes.Interface, namespace, gateway string, servicePort int32) (labels.Selector, int, error) {
	list, err := clientset.CoreV1().Services(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "gateway.envoyproxy.io/owning-gateway-name=" + gateway,
	})
	if err != nil {
		return nil, 0, fmt.Errorf("framework: listing gateway Services in %s: %w", namespace, err)
	}
	if len(list.Items) == 0 {
		return nil, 0, fmt.Errorf("framework: no Service in %s owned by Gateway %q", namespace, gateway)
	}

	svc := list.Items[0]
	if len(svc.Spec.Selector) == 0 {
		return nil, 0, fmt.Errorf("framework: Service %s/%s has no pod selector", namespace, svc.Name)
	}
	for _, port := range svc.Spec.Ports {
		if port.Port != servicePort {
			continue
		}
		target := port.TargetPort.IntValue()
		if target == 0 {
			return nil, 0, fmt.Errorf("framework: Service %s/%s port %d has a named targetPort %q, which a port-forward cannot resolve",
				namespace, svc.Name, servicePort, port.TargetPort.String())
		}
		return labels.SelectorFromSet(svc.Spec.Selector), target, nil
	}
	return nil, 0, fmt.Errorf("framework: Service %s/%s has no port %d", namespace, svc.Name, servicePort)
}

// ServiceSelector returns a Service's pod selector, used to find a running
// pod to port-forward to without hardcoding an operator-specific label.
func ServiceSelector(ctx context.Context, clientset kubernetes.Interface, namespace, name string) (labels.Selector, error) {
	svc, err := clientset.CoreV1().Services(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("framework: getting Service %s/%s: %w", namespace, name, err)
	}
	if len(svc.Spec.Selector) == 0 {
		return nil, fmt.Errorf("framework: Service %s/%s has no pod selector", namespace, name)
	}
	return labels.SelectorFromSet(svc.Spec.Selector), nil
}

// FirstReadyPod returns the name of the first Running, Ready pod matching
// selector, for use as a port-forward target.
func FirstReadyPod(ctx context.Context, clientset kubernetes.Interface, namespace string, selector labels.Selector) (string, error) {
	pods, err := clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{LabelSelector: selector.String()})
	if err != nil {
		return "", fmt.Errorf("framework: listing pods in %s matching %q: %w", namespace, selector, err)
	}

	for _, pod := range pods.Items {
		if pod.Status.Phase != corev1.PodRunning {
			continue
		}
		for _, cond := range pod.Status.Conditions {
			if cond.Type == corev1.PodReady && cond.Status == corev1.ConditionTrue {
				return pod.Name, nil
			}
		}
	}

	return "", fmt.Errorf("framework: no Running/Ready pod in %s matching %q", namespace, selector)
}
