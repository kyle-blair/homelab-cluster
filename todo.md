# Roadmap

- [ ] Harden monitoring stack ingress with authentication (high priority for securing dashboards)
- [ ] Migrate Loki persistence to network storage with redundancy (prevents data loss on node failure)
- [x] Automate TLS certificate provisioning for external domains (removes manual secret handling)
- [ ] Create Grafana dashboards for critical workloads and SLOs (ensures actionable observability)
- [ ] Configure alert routing and notifications for on-call channels (close the loop on monitoring)
- [ ] Rename the Kubernetes cluster SSH user to something like `cluster-operator` so it is distinct from other operator accounts such as `host-operator`
