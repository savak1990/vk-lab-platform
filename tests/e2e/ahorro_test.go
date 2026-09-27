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
	// What the image's own config.json carries. Seeing it served means the
	// chart's ConfigMap did not reach the container.
	bakedApiBaseUrl = "http://localhost:8080"
)

// Reached by forwarding to the Services on every target, not through a route:
// the application publishes none on local, and forwarding works the same
// everywhere, so one path serves all four. Both probes are unauthenticated -
// this is a smoke check that the delivery chain arrived, not a test of
// sign-in, which runs against the real hostnames and the real pool elsewhere.
//
// Nothing here may assert a target-specific value: on a cloud target the
// URLs are built from the platform's fqdn.
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

		// The value, not merely a 200. The image bakes its own config.json,
		// so a ConfigMap mount that silently failed would still answer 200
		// with that plausible-looking default.
		//
		// Checked as "not the baked default" rather than against the expected
		// URL: that URL differs per target, and on a cloud target it is built
		// from the platform's fqdn, which is a value no test may carry.
		Expect(config).To(HaveKey("apiBaseUrl"))
		Expect(config["apiBaseUrl"]).NotTo(BeEmpty(),
			"the chart must render an API base URL")
		Expect(config["apiBaseUrl"]).NotTo(Equal(bakedApiBaseUrl),
			"config.json is the one baked into the image, so the ConfigMap never mounted")

		// Present on every target; true only where there is no user pool, so
		// the value itself is not asserted here.
		Expect(config).To(HaveKey("authDisabled"))
	})
})
