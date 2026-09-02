package e2e_test

import (
	"os"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/ginkgo/v2/types"
	. "github.com/onsi/gomega"
	"k8s.io/client-go/dynamic"

	"github.com/savak1990/vk-lab-platform/tests/e2e/framework"
)

var (
	env framework.Environment
	cfg *framework.Config
)

// TestMain parses our flags before testing's own flag.Parse runs (called by
// go test's generated main), since a flag registered later would otherwise
// be rejected as "provided but not defined".
func TestMain(m *testing.M) {
	cfg = framework.ParseFlags()
	os.Exit(m.Run())
}

func TestE2E(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "E2E Suite")
}

var _ = BeforeSuite(func() {
	clientset, restConfig, err := framework.NewClientset(cfg.KubeconfigPath, cfg.Context)
	Expect(err).NotTo(HaveOccurred(), "building Kubernetes client for context %q", cfg.Context)

	dynamicClient, err := dynamic.NewForConfig(restConfig)
	Expect(err).NotTo(HaveOccurred(), "building dynamic client for context %q", cfg.Context)

	env = framework.NewAWSEnvironment(clientset, dynamicClient, restConfig)
})

var _ = AfterSuite(func() {
	env.Close()
})

var _ = ReportAfterEach(func(report SpecReport) {
	if !report.State.Is(types.SpecStateFailed) {
		return
	}
	// Diagnostics are dumped per-service (each service test knows its own
	// namespace/selector); this suite-wide hook exists only for context.
	GinkgoWriter.Printf("--- spec failed: %s ---\n", report.FullText())
})
