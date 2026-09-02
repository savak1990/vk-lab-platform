package framework

import (
	"context"
	"fmt"
	"io"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const diagnosticsLogTailLines = 50

// DumpPodDiagnostics writes pod status/events/log-tail for pods matching
// labelSelector in namespace to w. Called from suite_test.go's
// ReportAfterEach when a spec has failed — a failed Eventually() with no
// diagnostic output is the most common source of wasted CI-debugging time.
func DumpPodDiagnostics(ctx context.Context, clientset kubernetes.Interface, namespace, labelSelector string, w io.Writer) {
	pods, err := clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{LabelSelector: labelSelector})
	if err != nil {
		fmt.Fprintf(w, "diagnostics: listing pods in %s matching %q: %v\n", namespace, labelSelector, err)
		return
	}
	if len(pods.Items) == 0 {
		fmt.Fprintf(w, "diagnostics: no pods in %s matching %q\n", namespace, labelSelector)
		return
	}

	for _, pod := range pods.Items {
		fmt.Fprintf(w, "--- pod %s/%s (phase=%s) ---\n", pod.Namespace, pod.Name, pod.Status.Phase)
		for _, cond := range pod.Status.Conditions {
			fmt.Fprintf(w, "  condition %s=%s (%s: %s)\n", cond.Type, cond.Status, cond.Reason, cond.Message)
		}
		for _, cs := range pod.Status.ContainerStatuses {
			fmt.Fprintf(w, "  container %s ready=%t restarts=%d state=%s\n", cs.Name, cs.Ready, cs.RestartCount, containerStateSummary(cs.State))
		}

		dumpPodLogTail(ctx, clientset, w, pod)
	}

	dumpRecentEvents(ctx, clientset, w, namespace)
}

func dumpPodLogTail(ctx context.Context, clientset kubernetes.Interface, w io.Writer, pod corev1.Pod) {
	var tailLines int64 = diagnosticsLogTailLines
	req := clientset.CoreV1().Pods(pod.Namespace).GetLogs(pod.Name, &corev1.PodLogOptions{TailLines: &tailLines})
	stream, err := req.Stream(ctx)
	if err != nil {
		fmt.Fprintf(w, "  logs: %v\n", err)
		return
	}
	defer stream.Close()

	fmt.Fprintf(w, "  last %d log lines:\n", diagnosticsLogTailLines)
	if _, err := io.Copy(w, stream); err != nil {
		fmt.Fprintf(w, "  logs: reading stream: %v\n", err)
	}
}

func dumpRecentEvents(ctx context.Context, clientset kubernetes.Interface, w io.Writer, namespace string) {
	events, err := clientset.CoreV1().Events(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		fmt.Fprintf(w, "diagnostics: listing events in %s: %v\n", namespace, err)
		return
	}

	fmt.Fprintf(w, "--- recent events in %s ---\n", namespace)
	for _, event := range events.Items {
		fmt.Fprintf(w, "  [%s] %s/%s: %s\n", event.Type, event.InvolvedObject.Kind, event.InvolvedObject.Name, event.Message)
	}
}

func containerStateSummary(state corev1.ContainerState) string {
	switch {
	case state.Waiting != nil:
		return fmt.Sprintf("waiting(%s: %s)", state.Waiting.Reason, state.Waiting.Message)
	case state.Terminated != nil:
		return fmt.Sprintf("terminated(%s, exit=%d)", state.Terminated.Reason, state.Terminated.ExitCode)
	case state.Running != nil:
		return "running"
	default:
		return "unknown"
	}
}
