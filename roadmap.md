# Roadmap

- [x] Harden monitoring stack ingress with authentication (high priority for
    securing dashboards).
- [x] Automate tls certificate provisioning for external domains (removes
    manual secret handling)
- [ ] Make services robust and reslient.
- [ ] Security hardening.
    Kubespray has insecure defaults, specifically kube_api_anonymous_auth.
- [ ] Configure alerting with a real-world notification mechanism (probably
    email for now).
- [ ] Confirm that serious issues trigger notifications.
- [ ] Lay out some basic functional tests.
- [ ] Add some form of cluster management.
    Maybe that is implemented as a dependency manager pointed at the repo.
	Maybe it's in the form of operators running inside the cluster.
- [ ] Add architectural decision records.
- [ ] Add a dns service.
- [x] Add a dhcp service.
- [ ] Plan out storage.
- [ ] Rename the Kubernetes cluster ssh user to something like
    `cluster-operator` so it is distinct from other operator accounts such as
    `host-operator`.
- [ ] Investigate defining the cluster declaritively. I recall seeing
    kubernetes projects working on this.
- [ ] Investigate having an agent monitor logs for issues. It can at least
    proactively research a root cause and/or fix.
- [ ] Add a git provider/hosting service to the cluster.
- [ ] Make the local repo the primary one and mirror changes to github.
- [ ] Point argocd at the local repository.
- [ ] Document features/goals/motivations.
- [ ] Migrate services to implementation-agnostic host names?
