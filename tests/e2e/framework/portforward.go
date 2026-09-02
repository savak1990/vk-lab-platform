package framework

import (
	"fmt"
	"net/http"
	"strconv"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
)

// PortForward opens a port-forward to remotePort on the given pod and
// returns the local port it was bound to, plus a channel to close to tear
// it down. Used for services with no external hostname (Postgres) — Grafana
// and Argo CD are reached via their public HTTPRoute hostname instead.
func PortForward(restConfig *rest.Config, clientset kubernetes.Interface, namespace, podName string, remotePort int) (int, chan struct{}, error) {
	req := clientset.CoreV1().RESTClient().Post().
		Resource("pods").
		Namespace(namespace).
		Name(podName).
		SubResource("portforward")

	transport, upgrader, err := spdy.RoundTripperFor(restConfig)
	if err != nil {
		return 0, nil, fmt.Errorf("framework: building SPDY round tripper: %w", err)
	}
	dialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, "POST", req.URL())

	stopCh := make(chan struct{}, 1)
	readyCh := make(chan struct{})
	ports := []string{fmt.Sprintf("0:%d", remotePort)}

	fw, err := portforward.New(dialer, ports, stopCh, readyCh, nil, nil)
	if err != nil {
		return 0, nil, fmt.Errorf("framework: creating port-forwarder: %w", err)
	}

	errCh := make(chan error, 1)
	go func() { errCh <- fw.ForwardPorts() }()

	select {
	case err := <-errCh:
		return 0, nil, fmt.Errorf("framework: port-forward to %s/%s:%d failed: %w", namespace, podName, remotePort, err)
	case <-readyCh:
	}

	forwarded, err := fw.GetPorts()
	if err != nil || len(forwarded) == 0 {
		close(stopCh)
		return 0, nil, fmt.Errorf("framework: reading forwarded port: %w", err)
	}

	localPort, err := strconv.Atoi(strconv.FormatUint(uint64(forwarded[0].Local), 10))
	if err != nil {
		close(stopCh)
		return 0, nil, fmt.Errorf("framework: parsing forwarded local port: %w", err)
	}

	return localPort, stopCh, nil
}
