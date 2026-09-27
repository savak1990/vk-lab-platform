package e2e_test

import (
	"encoding/json"
	"io"
	"net/http"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	ahorroNamespace = "ahorro"
	ahorroPort      = 8080
)

// The application publishes no HTTPRoute on the local target, so these reach
// it by forwarding to the Services. Both probes are unauthenticated: this is
// a smoke check that the delivery chain arrived, not a test of sign-in.
var _ = Describe("Ahorro", Label("ahorro"), func() {
	It("serves the API health probe", func() {
		url := env.ForwardedServiceURL(ahorroNamespace, "ahorro-api", ahorroPort)
		client := cfg.HTTPClient()

		Eventually(func() (int, error) {
			resp, err := client.Get(url + "/healthz")
			if err != nil {
				return 0, err
			}
			defer resp.Body.Close()
			return resp.StatusCode, nil
		}).Should(Equal(http.StatusOK))
	})

	It("serves the client and the runtime configuration the browser reads", func() {
		url := env.ForwardedServiceURL(ahorroNamespace, "ahorro-web", ahorroPort)
		client := cfg.HTTPClient()

		Eventually(func() (int, error) {
			resp, err := client.Get(url + "/healthz")
			if err != nil {
				return 0, err
			}
			defer resp.Body.Close()
			return resp.StatusCode, nil
		}).Should(Equal(http.StatusOK))

		resp, err := client.Get(url + "/config.json")
		Expect(err).NotTo(HaveOccurred())
		defer resp.Body.Close()
		Expect(resp.StatusCode).To(Equal(http.StatusOK))

		body, err := io.ReadAll(resp.Body)
		Expect(err).NotTo(HaveOccurred())

		var config map[string]any
		Expect(json.Unmarshal(body, &config)).To(Succeed(), "config.json must be valid JSON: %s", body)

		// The value, not merely a 200. The image ships a committed
		// config.json of its own, so a ConfigMap mount that silently failed
		// would still answer 200 with a plausible-looking localhost:8080.
		Expect(config).To(HaveKeyWithValue("apiBaseUrl", "http://localhost:8091"),
			"the chart's apiBaseUrl must have replaced the one baked into the image")
		Expect(config).To(HaveKeyWithValue("authDisabled", true),
			"this target has no user pool, so the client must be told to skip sign-in")
	})
})
