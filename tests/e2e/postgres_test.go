package e2e_test

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	postgresNamespace   = "cnpg-system"
	postgresClusterName = "lab-postgres"
)

var _ = Describe("Postgres", Label("postgres"), func() {
	It("has a ready CNPG operator and cluster", func() {
		Eventually(func() (bool, error) {
			deploys, err := env.KubernetesClient().AppsV1().Deployments(postgresNamespace).List(context.Background(), metav1.ListOptions{
				LabelSelector: "app.kubernetes.io/name=cloudnative-pg",
			})
			if err != nil {
				return false, err
			}
			if len(deploys.Items) == 0 {
				return false, nil
			}
			return deploymentReady(&deploys.Items[0]), nil
		}).Should(BeTrue(), "the cloudnative-pg operator Deployment must be ready")

		_, err := env.KubernetesClient().CoreV1().Services(postgresNamespace).Get(context.Background(), postgresClusterName+"-rw", metav1.GetOptions{})
		Expect(err).NotTo(HaveOccurred(), "%s-rw Service must exist", postgresClusterName)

		_, err = env.KubernetesClient().CoreV1().Secrets(postgresNamespace).Get(context.Background(), postgresClusterName+"-app", metav1.GetOptions{})
		Expect(err).NotTo(HaveOccurred(), "%s-app Secret must exist", postgresClusterName)
	})

	It("accepts connections and full read/write access", func() {
		dsn := env.PostgresDSN(postgresClusterName)

		var conn *pgx.Conn
		Eventually(func() error {
			c, err := pgx.Connect(context.Background(), dsn)
			if err != nil {
				return err
			}
			conn = c
			return nil
		}).Should(Succeed())
		defer conn.Close(context.Background())

		var result int
		Expect(conn.QueryRow(context.Background(), "SELECT 1").Scan(&result)).To(Succeed())
		Expect(result).To(Equal(1))

		table := fmt.Sprintf("e2e_perm_%d", GinkgoRandomSeed())
		_, err := conn.Exec(context.Background(), fmt.Sprintf("CREATE TABLE %s (id int)", table))
		Expect(err).NotTo(HaveOccurred(), "app user must have DDL permission")
		DeferCleanup(func() {
			_, _ = conn.Exec(context.Background(), fmt.Sprintf("DROP TABLE IF EXISTS %s", table))
		})
	})
})

func deploymentReady(deploy *appsv1.Deployment) bool {
	return deploy.Status.ReadyReplicas > 0 && deploy.Status.ReadyReplicas == *deploy.Spec.Replicas
}
