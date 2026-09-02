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

// ResolveHTTPRouteHostname reads a Gateway API HTTPRoute's first hostname.
// Using the dynamic client here avoids pulling in the full gateway-api
// generated client for a single-field read.
func ResolveHTTPRouteHostname(ctx context.Context, dynamicClient dynamic.Interface, namespace, name string) (string, error) {
	route, err := dynamicClient.Resource(httpRouteGVR).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return "", fmt.Errorf("framework: getting HTTPRoute %s/%s: %w", namespace, name, err)
	}

	hostnames, found, err := unstructured.NestedStringSlice(route.Object, "spec", "hostnames")
	if err != nil || !found || len(hostnames) == 0 {
		return "", fmt.Errorf("framework: HTTPRoute %s/%s has no spec.hostnames", namespace, name)
	}

	return hostnames[0], nil
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
