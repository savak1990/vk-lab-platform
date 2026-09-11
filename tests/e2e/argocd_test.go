package e2e_test

import (
	"net/http"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Argo CD", Label("argocd"), func() {
	It("is reachable and healthy", func() {
		url := env.ServiceURL("argocd") + "/healthz"

		client := cfg.HTTPClient()
		Eventually(func() (int, error) {
			resp, err := client.Get(url)
			if err != nil {
				return 0, err
			}
			defer resp.Body.Close()
			return resp.StatusCode, nil
		}).Should(Equal(http.StatusOK))
	})
})
