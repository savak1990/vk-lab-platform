package e2e_test

import (
	"context"
	"net/http"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const grafanaNamespace = "observability"

var _ = Describe("Grafana", Label("grafana"), func() {
	It("is healthy and accepts authenticated requests", func() {
		url := env.ServiceURL("grafana")

		Eventually(func() (int, error) {
			resp, err := http.Get(url + "/api/health")
			if err != nil {
				return 0, err
			}
			defer resp.Body.Close()
			return resp.StatusCode, nil
		}).Should(Equal(http.StatusOK))

		secret, err := env.KubernetesClient().CoreV1().Secrets(grafanaNamespace).Get(context.Background(), "grafana-admin-credentials", metav1.GetOptions{})
		Expect(err).NotTo(HaveOccurred(), "grafana-admin-credentials Secret must exist")

		req, err := http.NewRequest(http.MethodGet, url+"/api/dashboards/home", nil)
		Expect(err).NotTo(HaveOccurred())
		req.SetBasicAuth(string(secret.Data["admin-user"]), string(secret.Data["admin-password"]))

		resp, err := http.DefaultClient.Do(req)
		Expect(err).NotTo(HaveOccurred())
		defer resp.Body.Close()
		Expect(resp.StatusCode).To(Equal(http.StatusOK), "authenticated call must succeed with the synced admin credentials")
	})
})
