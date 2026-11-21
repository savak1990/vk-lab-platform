# 0046. Business-application child Applications live in the application's own namespace

Date: 2026-11-21

Status: Accepted. Amends ADR 0015 and ADR 0043.

## Context

ADR 0015 gave each business application its own AppProject so that its
repository cannot reach outside its namespace. ADR 0043 placed the first
pointer Application and let the repository's child Applications be created
in namespace `argocd`, which forced the AppProject to list `argocd` as a
destination with an unrestricted resource whitelist.

Argo CD treats every Application in its control-plane namespace as trusted:
such an Application may name any project, including `default`. The 2026-11-21
security review showed two consequences. A push to the application repository
could create a child in project `default`, which is cluster-admin. It could
also overwrite `argocd-cm`, `argocd-rbac-cm` or `argocd-secret`, which would
open the public Argo CD UI to anonymous administrators.

## Decision

Argo CD runs with `application.namespaces=ahorro`. The `vk-ahorro` AppProject
lists `ahorro` in `sourceNamespaces` and in `destinations`, and no longer lists
`argocd`. The pointer Application's destination is `ahorro`, so the
repository's child Applications are created there. An Application in `ahorro`
must name a project whose `sourceNamespaces` includes `ahorro`; only
`vk-ahorro` does, so a child cannot escape its project.

The same shape applies to every future business application: one AppProject,
one source namespace, one destination namespace, never `argocd`.

## Consequences

- The vk-ahorro repository's child Applications carry
  `metadata.namespace: ahorro`.
- `argocd app` commands on a child need `-N ahorro` or the `ahorro/<name>`
  form.
- Moving the existing children deletes and recreates them once. With the
  `resources-finalizer` stripped from the old objects first, the workloads
  stay up and the new children adopt them through server-side apply.
