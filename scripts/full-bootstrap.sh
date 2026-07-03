#!/usr/bin/env bash
set -euo pipefail

: "${ARGOCD_VERSION:=v3.1.8}"
: "${KUBESPRAY_IMAGE:=quay.io/kubespray/kubespray:v2.31.0}"
: "${KUBESPRAY_PLAYBOOK:=cluster.yml}"
: "${KUBECONFIG_SSH_TARGET:=}"
: "${CLUSTER_DOMAIN:=home.arpa}"
: "${ARGOCD_CLI_LOGIN:=false}"
: "${ARGOCD_CLI_SERVER:=argocd.${CLUSTER_DOMAIN}}"
: "${ARGOCD_CLI_SSO:=true}"
: "${ARGOCD_CLI_INSECURE:=false}"
: "${BOOTSTRAP_GENERATED_SECRET_BYTES:=48}"
: "${AUTH_ADMIN_USERNAME:=admin}"
: "${AUTH_ADMIN_EMAIL:=admin@${CLUSTER_DOMAIN}}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTS_PATH="${REPO_ROOT}/infrastructure/hosts.yaml"
SSH_PRIVATE_KEY="${HOME}/.ssh/id_rsa"
SSH_KNOWN_HOSTS="${HOME}/.ssh/known_hosts"
PROVISION_CLUSTER=false
CA_CRT=""
CA_KEY=""
LOAD_BALANCER_ADDRESSES=""
GENERATED_KUBECONFIG=""
ARTIFACTS_DIR="${REPO_ROOT}/infrastructure/artifacts"
FORCE_RESEAL_SEALED_SECRET=""

usage() {
  cat <<USAGE >&2
Usage: ${0##*/} [options]

Builds the cluster, seals required secrets into the repo, and bootstraps Argo CD.

Options:
  --provision-cluster          Run Kubespray through Podman before bootstrapping apps.
  --hosts PATH                 Ansible-style hosts inventory path.
                               Default: infrastructure/hosts.yaml
  --load-balancer-addresses RANGE
                               Update the repo-defined MetalLB range.
  --domain DOMAIN              Update repo-defined service domains.
                               Default: home.arpa
  --ssh-private-key PATH       SSH key used for Kubespray and kubeconfig fetch.
                               Default: ~/.ssh/id_rsa
  --ssh-known-hosts PATH       SSH known_hosts file used for host verification.
                               Default: ~/.ssh/known_hosts
  --ca-crt PATH                Intermediate CA certificate for cert-manager.
                               Required until apps/cert-manager/internal-ca.sealed.yaml exists.
  --ca-key PATH                Intermediate CA private key for cert-manager.
                               Required until apps/cert-manager/internal-ca.sealed.yaml exists.
  --admin-username USERNAME    LDAP admin username.
                               Default: admin
  --admin-email EMAIL          LDAP admin email address.
                               Default: admin@home.arpa
  -h, --help                   Show this help.

Environment:
  ARGOCD_VERSION               Upstream Argo CD install manifest tag.
                               Default: v3.1.8
  KUBESPRAY_IMAGE              Kubespray container image.
                               Default: quay.io/kubespray/kubespray:v2.31.0
  KUBESPRAY_PLAYBOOK           Kubespray playbook inside the container.
                               Default: cluster.yml
  KUBECONFIG_SSH_TARGET        SSH target used to fetch admin.conf.
                               Default: first kube_control_plane inventory host.
  ARGOCD_CLI_LOGIN             Log the local argocd CLI in after bootstrap.
                               Default: false
  ARGOCD_CLI_SERVER            Argo CD ingress hostname used for argocd CLI login.
                               Default: argocd.home.arpa
  ARGOCD_CLI_SSO               Use browser SSO for argocd CLI login.
                               Default: true
  ARGOCD_CLI_INSECURE          Disable TLS certificate verification for argocd CLI login.
                               Default: false
  BOOTSTRAP_GENERATED_SECRET_BYTES
                               Random byte length for generated bootstrap secrets.
                               Default: 48
  AUTH_ADMIN_USERNAME          LDAP admin username.
                               Default: admin
  AUTH_ADMIN_EMAIL             LDAP admin email address.
                               Default: admin@home.arpa
  CLUSTER_DOMAIN               Base DNS domain for printed service URLs.
                               Default: home.arpa
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --provision-cluster)
      PROVISION_CLUSTER=true
      shift
      ;;
    --hosts)
      HOSTS_PATH=${2:?--hosts requires a path}
      shift 2
      ;;
    --load-balancer-addresses)
      LOAD_BALANCER_ADDRESSES=${2:?--load-balancer-addresses requires a range}
      shift 2
      ;;
    --domain)
      local_default_admin_email="admin@${CLUSTER_DOMAIN}"
      CLUSTER_DOMAIN=${2:?--domain requires a domain}
      ARGOCD_CLI_SERVER="argocd.${CLUSTER_DOMAIN}"
      if [ "$AUTH_ADMIN_EMAIL" = "$local_default_admin_email" ]; then
        AUTH_ADMIN_EMAIL="admin@${CLUSTER_DOMAIN}"
      fi
      shift 2
      ;;
    --ssh-private-key)
      SSH_PRIVATE_KEY=${2:?--ssh-private-key requires a path}
      shift 2
      ;;
    --ssh-known-hosts)
      SSH_KNOWN_HOSTS=${2:?--ssh-known-hosts requires a path}
      shift 2
      ;;
    --ca-crt)
      CA_CRT=${2:?--ca-crt requires a path}
      shift 2
      ;;
    --ca-key)
      CA_KEY=${2:?--ca-key requires a path}
      shift 2
      ;;
    --admin-username)
      AUTH_ADMIN_USERNAME=${2:?--admin-username requires a username}
      shift 2
      ;;
    --admin-email)
      AUTH_ADMIN_EMAIL=${2:?--admin-email requires an email address}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 64
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 69
  fi
}

resolve_kubeconfig_ssh_target() {
  if [ -n "$KUBECONFIG_SSH_TARGET" ]; then
    printf '%s\n' "$KUBECONFIG_SSH_TARGET"
    return 0
  fi

  require_command ruby
  ruby -ryaml -e '
    inventory = YAML.load_file(ARGV.fetch(0))
    all = inventory.fetch("all", {})
    all_hosts = all.fetch("hosts", {}) || {}
    control_hosts = all.dig("children", "kube_control_plane", "hosts") || {}
    host_name = control_hosts.keys.first || all_hosts.keys.find { |name| name =~ /control|master/i } || all_hosts.keys.first

    if host_name.nil?
      warn "No hosts found in inventory"
      exit 66
    end

    attrs = {}
    attrs.merge!(all_hosts.fetch(host_name, {}) || {})
    attrs.merge!(control_hosts.fetch(host_name, {}) || {})
    host = attrs["ansible_host"] || attrs["access_ip"] || attrs["ip"] || host_name
    user = attrs["ansible_user"]

    puts user ? "#{user}@#{host}" : host
  ' "$HOSTS_PATH"
}

validate_inputs() {
  if ! [[ "$CLUSTER_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$CLUSTER_DOMAIN" == .* ]] || [[ "$CLUSTER_DOMAIN" == *..* ]] || [[ "$CLUSTER_DOMAIN" == *. ]]; then
    echo "Invalid domain: $CLUSTER_DOMAIN" >&2
    exit 64
  fi

  if [ -n "$LOAD_BALANCER_ADDRESSES" ] && ! [[ "$LOAD_BALANCER_ADDRESSES" =~ ^[0-9A-Fa-f:.]+([/-][0-9A-Fa-f:.]+)?$ ]]; then
    echo "Invalid load balancer address range: $LOAD_BALANCER_ADDRESSES" >&2
    exit 64
  fi

  if ! [[ "$AUTH_ADMIN_USERNAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid admin username: $AUTH_ADMIN_USERNAME" >&2
    exit 64
  fi

  if ! [[ "$AUTH_ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
    echo "Invalid admin email address: $AUTH_ADMIN_EMAIL" >&2
    exit 64
  fi

  if [ ! -f "${REPO_ROOT}/apps/cert-manager/internal-ca.sealed.yaml" ]; then
    if [ -z "$CA_CRT" ] || [ -z "$CA_KEY" ]; then
      echo "Internal CA input is required until apps/cert-manager/internal-ca.sealed.yaml exists." >&2
      echo "Pass --ca-crt and --ca-key for an intermediate CA signed by your root authority." >&2
      exit 64
    fi
  fi
}

replace_in_file() {
  local file=$1
  local old=$2
  local new=$3

  local before
  before="$(mktemp)"
  cp "$file" "$before"
  perl -0pi -e 'BEGIN { ($old, $new) = splice(@ARGV, 0, 2) } s/\Q$old\E/$new/g' "$old" "$new" "$file"
  if ! cmp -s "$before" "$file"; then
    REPO_CONFIG_CHANGED=true
  fi
  rm -f "$before"
}

set_yaml_list_value() {
  local file=$1
  local value=$2

  local before
  before="$(mktemp)"
  cp "$file" "$before"
  perl -0pi -e 'BEGIN { $value = shift @ARGV } s/^(\s*-\s*)[0-9A-Fa-f:.]+(?:[\/-][0-9A-Fa-f:.]+)?$/${1}$value/m' "$value" "$file"
  if ! cmp -s "$before" "$file"; then
    REPO_CONFIG_CHANGED=true
  fi
  rm -f "$before"
}

configure_repo_manifests() {
  REPO_CONFIG_CHANGED=false

  if [ "$CLUSTER_DOMAIN" != "home.arpa" ]; then
    echo "[full-bootstrap] Updating repo manifests for domain $CLUSTER_DOMAIN"
    local cluster_base_dn
    cluster_base_dn="$(domain_to_dn "$CLUSTER_DOMAIN")"
    local files=(
      apps/auth-gateway/configuration.yaml
      apps/auth-gateway/ingress.yaml
      apps/argocd/config-map.yaml
      apps/argocd-config/certificate.yaml
      apps/argocd-config/ingress.yaml
      apps/ldap/deployment.yaml
      apps/monitoring-config/alertmanager-certificate.yaml
      apps/monitoring-config/alertmanager-ingress.yaml
      apps/monitoring-config/grafana-certificate.yaml
      apps/monitoring-config/grafana-ingress.yaml
      apps/monitoring-config/prometheus-certificate.yaml
      apps/monitoring-config/prometheus-ingress.yaml
    )
    local file
    for file in "${files[@]}"; do
      replace_in_file "${REPO_ROOT}/${file}" "home.arpa" "$CLUSTER_DOMAIN"
      replace_in_file "${REPO_ROOT}/${file}" "dc=home,dc=arpa" "$cluster_base_dn"
    done
  fi

  if [ -n "$LOAD_BALANCER_ADDRESSES" ]; then
    echo "[full-bootstrap] Updating repo MetalLB range to $LOAD_BALANCER_ADDRESSES"
    set_yaml_list_value "${REPO_ROOT}/apps/load-balancer/default-ip-pool.yaml" "$LOAD_BALANCER_ADDRESSES"
  fi

  if [ "$REPO_CONFIG_CHANGED" = true ]; then
    echo "[full-bootstrap] Repo manifests were updated from bootstrap inputs."
    echo "[full-bootstrap] Commit and push these changes, then rerun bootstrap so Argo CD can sync the declared state." >&2
    git diff --stat -- \
      apps/auth-gateway/configuration.yaml \
      apps/auth-gateway/ingress.yaml \
      apps/argocd/config-map.yaml \
      apps/argocd-config/certificate.yaml \
      apps/argocd-config/ingress.yaml \
      apps/ldap/deployment.yaml \
      apps/load-balancer/default-ip-pool.yaml \
      apps/monitoring-config
    exit 75
  fi
}

add_kustomization_resource() {
  local kustomization=$1
  local resource=$2

  if grep -qx "  - ${resource}" "$kustomization"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk -v resource="  - ${resource}" '
    BEGIN { in_resources = 0; inserted = 0 }
    /^resources:[[:space:]]*$/ {
      in_resources = 1
      print
      next
    }
    in_resources && /^[^[:space:]-][^:]*:/ {
      if (!inserted) {
        print resource
        inserted = 1
      }
      in_resources = 0
    }
    { print }
    END {
      if (in_resources && !inserted) {
        print resource
        inserted = 1
      }
      if (!inserted) {
        print "resources:"
        print resource
      }
    }
  ' "$kustomization" >"$tmp"
  mv "$tmp" "$kustomization"
  REPO_CONFIG_CHANGED=true
}

seal_secret_manifest() {
  local source=$1
  local target=$2

  require_command kubeseal

  kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --format yaml \
    <"$source" >"$target"
  REPO_CONFIG_CHANGED=true
}

sealed_secret_valid() {
  local path=$1

  [ -f "$path" ] || return 1
  kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --validate \
    <"$path" >/dev/null 2>&1
}

sealed_secret_needs_update() {
  local path=$1

  if [ -n "$FORCE_RESEAL_SEALED_SECRET" ]; then
    case "$path" in
      *"/${FORCE_RESEAL_SEALED_SECRET}.sealed.yaml")
        return 0
        ;;
    esac
  fi

  if sealed_secret_valid "$path"; then
    return 1
  fi

  return 0
}

wait_for_sealed_secrets() {
  echo "[full-bootstrap] Waiting for Sealed Secrets controller"
  wait_for_argocd_application sealed-secrets "Sealed Secrets Argo CD application"
  wait_for_cluster_resource crd/sealedsecrets.bitnami.com "Sealed Secrets custom resource definition"

  kubectl wait \
    --for condition=Established \
    --timeout=180s \
    crd/sealedsecrets.bitnami.com

  kubectl rollout status deployment/sealed-secrets-controller \
    --namespace kube-system \
    --timeout=300s
}

apply_sealed_secret_manifests() {
  local manifest
  local applied

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  echo "[full-bootstrap] Applying SealedSecret manifests to the cluster"
  for manifest in "$@"; do
    if [ ! -f "$manifest" ]; then
      continue
    fi

    applied=false
    for _ in $(seq 1 60); do
      if kubectl apply --filename "$manifest"; then
        applied=true
        break
      fi
      sleep 5
    done

    if [ "$applied" != true ]; then
      echo "Failed to apply regenerated SealedSecret manifest: $manifest" >&2
      return 1
    fi
  done
}

ensure_sealed_secret_manifests() {
  require_command kubectl
  require_command kubeseal
  require_command openssl

  REPO_CONFIG_CHANGED=false
  mkdir -p "$ARTIFACTS_DIR"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  local bootstrap_ldap_admin_password=""
  local internal_ca_target="${REPO_ROOT}/apps/cert-manager/internal-ca.sealed.yaml"
  local ldap_admin_target="${REPO_ROOT}/apps/ldap/ldap-admin.sealed.yaml"
  local auth_gateway_target="${REPO_ROOT}/apps/auth-gateway/auth-gateway-secrets.sealed.yaml"
  local auth_admin_target="${REPO_ROOT}/apps/auth-gateway/auth-admin-user.sealed.yaml"
  local update_internal_ca=false
  local update_ldap_admin=false
  local update_auth_gateway=false
  local update_auth_admin=false

  if sealed_secret_needs_update "$internal_ca_target"; then
    update_internal_ca=true
  fi
  if sealed_secret_needs_update "$ldap_admin_target"; then
    update_ldap_admin=true
  fi
  if sealed_secret_needs_update "$auth_gateway_target"; then
    update_auth_gateway=true
  fi
  if sealed_secret_needs_update "$auth_admin_target"; then
    update_auth_admin=true
  fi

  if [ "$update_ldap_admin" = true ] || [ "$update_auth_gateway" = true ]; then
    bootstrap_ldap_admin_password="$(value_or_random auth ldap-admin LDAP_ADMIN_PASSWORD)"
  fi

  if [ "$update_internal_ca" = true ]; then
    if [ -z "$CA_CRT" ] || [ -z "$CA_KEY" ]; then
      echo "Internal CA input is required because the current cluster cannot decrypt apps/cert-manager/internal-ca.sealed.yaml." >&2
      echo "Pass --ca-crt and --ca-key for an intermediate CA signed by your root authority." >&2
      exit 64
    fi

    echo "[full-bootstrap] Sealing cert-manager internal CA into the repo"
    kubectl create secret tls internal-ca \
      --namespace cert-manager \
      --cert "$CA_CRT" \
      --key "$CA_KEY" \
      --dry-run=client \
      -o yaml >"${tmp_dir}/internal-ca.yaml"
    seal_secret_manifest "${tmp_dir}/internal-ca.yaml" "$internal_ca_target"
    cp "$CA_CRT" "${ARTIFACTS_DIR}/internal-ca.crt"
  fi

  if [ "$update_ldap_admin" = true ]; then
    echo "[full-bootstrap] Sealing LDAP admin secret into the repo"
    local ldap_admin_password
    local ldap_config_password
    ldap_admin_password="$bootstrap_ldap_admin_password"
    ldap_config_password="$(value_or_random auth ldap-admin LDAP_CONFIG_PASSWORD)"
    kubectl create secret generic ldap-admin \
      --namespace auth \
      --from-literal "LDAP_ADMIN_PASSWORD=${ldap_admin_password}" \
      --from-literal "LDAP_CONFIG_PASSWORD=${ldap_config_password}" \
      --dry-run=client \
      -o yaml >"${tmp_dir}/ldap-admin.yaml"
    seal_secret_manifest "${tmp_dir}/ldap-admin.yaml" "$ldap_admin_target"
  fi

  if [ "$update_auth_gateway" = true ]; then
    echo "[full-bootstrap] Sealing auth gateway secret into the repo"
    local jwt_secret
    local session_secret
    local storage_encryption_key
    local oidc_hmac_secret
    local oidc_jwks_key
    local ldap_password
    jwt_secret="$(value_or_random auth auth-gateway-secrets JWT_SECRET)"
    session_secret="$(value_or_random auth auth-gateway-secrets SESSION_SECRET)"
    storage_encryption_key="$(value_or_random auth auth-gateway-secrets STORAGE_ENCRYPTION_KEY)"
    oidc_hmac_secret="$(value_or_random auth auth-gateway-secrets OIDC_HMAC_SECRET)"
    oidc_jwks_key="$(get_secret_value auth auth-gateway-secrets OIDC_JWKS_KEY)"
    ldap_password="$bootstrap_ldap_admin_password"

    if [ -z "$oidc_jwks_key" ]; then
      oidc_jwks_key="$(openssl genrsa 2048 2>/dev/null)"
    fi
    if [ -z "$ldap_password" ]; then
      ldap_password="$(value_or_random auth ldap-admin LDAP_ADMIN_PASSWORD)"
    fi

    kubectl create secret generic auth-gateway-secrets \
      --namespace auth \
      --from-literal "JWT_SECRET=${jwt_secret}" \
      --from-literal "SESSION_SECRET=${session_secret}" \
      --from-literal "STORAGE_ENCRYPTION_KEY=${storage_encryption_key}" \
      --from-literal "LDAP_PASSWORD=${ldap_password}" \
      --from-literal "OIDC_HMAC_SECRET=${oidc_hmac_secret}" \
      --from-literal "OIDC_JWKS_KEY=${oidc_jwks_key}" \
      --dry-run=client \
      -o yaml >"${tmp_dir}/auth-gateway-secrets.yaml"
    seal_secret_manifest "${tmp_dir}/auth-gateway-secrets.yaml" "$auth_gateway_target"
  fi

  if [ "$update_auth_admin" = true ]; then
    echo "[full-bootstrap] Sealing LDAP admin user into the repo"
    local auth_admin_password
    auth_admin_password="$(value_or_random auth auth-admin-user PASSWORD)"
    kubectl create secret generic auth-admin-user \
      --namespace auth \
      --from-literal "USERNAME=${AUTH_ADMIN_USERNAME}" \
      --from-literal "EMAIL=${AUTH_ADMIN_EMAIL}" \
      --from-literal "DOMAIN=${CLUSTER_DOMAIN}" \
      --from-literal "PASSWORD=${auth_admin_password}" \
      --dry-run=client \
      -o yaml >"${tmp_dir}/auth-admin-user.yaml"
    seal_secret_manifest "${tmp_dir}/auth-admin-user.yaml" "$auth_admin_target"
  fi

  if [ -f "$internal_ca_target" ]; then
    add_kustomization_resource "${REPO_ROOT}/apps/cert-manager/kustomization.yaml" "internal-ca.sealed.yaml"
  fi
  if [ -f "$ldap_admin_target" ]; then
    add_kustomization_resource "${REPO_ROOT}/apps/ldap/kustomization.yaml" "ldap-admin.sealed.yaml"
  fi
  if [ -f "$auth_gateway_target" ]; then
    add_kustomization_resource "${REPO_ROOT}/apps/auth-gateway/kustomization.yaml" "auth-gateway-secrets.sealed.yaml"
  fi
  if [ -f "$auth_admin_target" ]; then
    add_kustomization_resource "${REPO_ROOT}/apps/auth-gateway/kustomization.yaml" "auth-admin-user.sealed.yaml"
  fi

  rm -rf "$tmp_dir"
  trap - RETURN

  if [ "$REPO_CONFIG_CHANGED" = true ]; then
    echo "[full-bootstrap] SealedSecret manifests were written to the repo." >&2
    apply_sealed_secret_manifests \
      "$internal_ca_target" \
      "$ldap_admin_target" \
      "$auth_gateway_target" \
      "$auth_admin_target"
    echo "[full-bootstrap] Commit and push these changes so Argo CD's declared state matches the cluster." >&2
    git diff --stat -- \
      apps/cert-manager \
      apps/ldap \
      apps/auth-gateway
  fi
}

run_kubespray() {
  require_command podman
  require_command ssh
  require_command scp

  if [ ! -f "$HOSTS_PATH" ]; then
    echo "Hosts inventory not found at $HOSTS_PATH" >&2
    echo "Copy infrastructure/hosts.example.yaml to infrastructure/hosts.yaml and edit it for your hosts." >&2
    exit 66
  fi

  if [ ! -f "$SSH_PRIVATE_KEY" ]; then
    echo "SSH private key not found at $SSH_PRIVATE_KEY" >&2
    exit 66
  fi

  local inventory_dir
  inventory_dir="$(cd "$(dirname "$HOSTS_PATH")" && pwd)"
  local inventory_file
  inventory_file="$(basename "$HOSTS_PATH")"
  local ssh_key_abs
  ssh_key_abs="$(cd "$(dirname "$SSH_PRIVATE_KEY")" && pwd)/$(basename "$SSH_PRIVATE_KEY")"
  GENERATED_KUBECONFIG="${ARTIFACTS_DIR}/admin.conf"
  mkdir -p "$ARTIFACTS_DIR"

  local podman_tty_args=()
  if [ -t 0 ] && [ -t 1 ]; then
    podman_tty_args=(-it)
  fi

  local podman_known_hosts_args=()
  local ssh_known_hosts_args=()
  if [ -f "$SSH_KNOWN_HOSTS" ]; then
    local known_hosts_abs
    known_hosts_abs="$(cd "$(dirname "$SSH_KNOWN_HOSTS")" && pwd)/$(basename "$SSH_KNOWN_HOSTS")"
    podman_known_hosts_args=(
      --mount "type=bind,src=${known_hosts_abs},dst=/root/.ssh/known_hosts,ro=true"
    )
    ssh_known_hosts_args=(
      -o "UserKnownHostsFile=${known_hosts_abs}"
    )
  else
    echo "[full-bootstrap] SSH known_hosts not found at $SSH_KNOWN_HOSTS; Kubespray may fail host key checks"
  fi

  echo "[full-bootstrap] Running Kubespray using $KUBESPRAY_IMAGE"
  podman run --rm "${podman_tty_args[@]}" \
    --network host \
    --mount "type=bind,src=${inventory_dir},dst=/inventory,rw=true" \
    --mount "type=bind,src=${ssh_key_abs},dst=/ssh/id_rsa,ro=true" \
    "${podman_known_hosts_args[@]}" \
    "$KUBESPRAY_IMAGE" \
    ansible-playbook \
      -i "/inventory/${inventory_file}" \
      --private-key /ssh/id_rsa \
      --become \
      "$KUBESPRAY_PLAYBOOK"

  local kubeconfig_ssh_target
  kubeconfig_ssh_target="$(resolve_kubeconfig_ssh_target)"
  local remote_kubeconfig
  remote_kubeconfig="/tmp/homelab-admin.conf-${RANDOM}-$$"

  echo "[full-bootstrap] Fetching kubeconfig from ${kubeconfig_ssh_target} to $GENERATED_KUBECONFIG"
  ssh -i "$ssh_key_abs" "${ssh_known_hosts_args[@]}" "$kubeconfig_ssh_target" \
    "sudo install -m 0600 -o \$(id -u) -g \$(id -g) /etc/kubernetes/admin.conf '${remote_kubeconfig}'"
  if ! scp -i "$ssh_key_abs" "${ssh_known_hosts_args[@]}" \
    "${kubeconfig_ssh_target}:${remote_kubeconfig}" "$GENERATED_KUBECONFIG"; then
    ssh -i "$ssh_key_abs" "${ssh_known_hosts_args[@]}" "$kubeconfig_ssh_target" \
      "rm -f '${remote_kubeconfig}'" || true
    exit 69
  fi
  ssh -i "$ssh_key_abs" "${ssh_known_hosts_args[@]}" "$kubeconfig_ssh_target" \
    "rm -f '${remote_kubeconfig}'"

  if [ -f "$GENERATED_KUBECONFIG" ]; then
    chmod 0600 "$GENERATED_KUBECONFIG"
    export KUBECONFIG="$GENERATED_KUBECONFIG"
    echo "[full-bootstrap] Using generated kubeconfig at $GENERATED_KUBECONFIG"
  fi
}

wait_for_api() {
  require_command kubectl

  echo "[full-bootstrap] Waiting for Kubernetes API access"
  for _ in $(seq 1 60); do
    if kubectl version --request-timeout=5s >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  echo "Kubernetes API did not become reachable through the active kubeconfig." >&2
  exit 69
}

random_secret() {
  require_command openssl
  openssl rand -base64 "$BOOTSTRAP_GENERATED_SECRET_BYTES" | tr -d '\n'
}

get_secret_value() {
  local namespace=$1
  local secret=$2
  local key=$3
  local value

  value="$(kubectl get secret "$secret" \
    --namespace "$namespace" \
    --output "jsonpath={.data.${key}}" 2>/dev/null || true)"

  if [ -n "$value" ]; then
    if printf '%s' "$value" | base64 --decode 2>/dev/null; then
      return 0
    fi
    printf '%s' "$value" | base64 -D
  fi
}

decode_base64_value() {
  local value=$1
  if printf '%s' "$value" | base64 --decode 2>/dev/null; then
    return 0
  fi

  printf '%s' "$value" | base64 -D
}

host_resolves() {
  local host=$1

  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" >/dev/null 2>&1
    return $?
  fi

  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "$host" >/dev/null 2>&1
    return $?
  fi

  if command -v host >/dev/null 2>&1; then
    host "$host" >/dev/null 2>&1
    return $?
  fi

  return 1
}

domain_to_dn() {
  local domain=$1
  local dn=""
  local part
  local parts

  IFS=. read -r -a parts <<<"$domain"
  for part in "${parts[@]}"; do
    if [ -n "$dn" ]; then
      dn="${dn},"
    fi
    dn="${dn}dc=${part}"
  done

  printf '%s' "$dn"
}

value_or_random() {
  local namespace=$1
  local secret=$2
  local key=$3
  local value

  value="$(get_secret_value "$namespace" "$secret" "$key")"
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi

  random_secret
}

bootstrap_argocd() {
  "${REPO_ROOT}/scripts/bootstrap-cluster.sh"
}

wait_for_resource() {
  local resource=$1
  local namespace=$2
  local description=$3

  echo "[full-bootstrap] Waiting for $description"
  for _ in $(seq 1 60); do
    if kubectl get "$resource" --namespace "$namespace" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  echo "Timed out waiting for $description." >&2
  return 1
}

wait_for_cluster_resource() {
  local resource=$1
  local description=$2

  echo "[full-bootstrap] Waiting for $description"
  for _ in $(seq 1 60); do
    if kubectl get "$resource" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  echo "Timed out waiting for $description." >&2
  return 1
}

print_sealed_secret_diagnostics() {
  local name=$1
  local namespace=$2
  local synced_condition

  echo "[full-bootstrap] Diagnostics for sealedsecret/$name in namespace $namespace" >&2
  kubectl get "sealedsecret/${name}" --namespace "$namespace" --output wide >&2 || true
  synced_condition="$(kubectl get "sealedsecret/${name}" \
    --namespace "$namespace" \
    --output "jsonpath={range .status.conditions[?(@.type=='Synced')]}{.status}{': '}{.message}{end}" 2>/dev/null || true)"
  if [ -n "$synced_condition" ]; then
    echo "[full-bootstrap] SealedSecret synced condition: $synced_condition" >&2
  fi
}

print_namespace_events() {
  local namespace=$1

  echo "[full-bootstrap] Recent events in namespace $namespace" >&2
  kubectl get events --namespace "$namespace" --sort-by=.lastTimestamp >&2 || true
}

sync_failure_needs_reseal() {
  local message=$1

  case "$message" in
    *"no key"*|*"No key"*|*"cannot decrypt"*|*"Cannot decrypt"*|*"failed to decrypt"*|*"Failed to decrypt"*)
      return 0
      ;;
  esac

  return 1
}

repair_sealed_secret_decryption() {
  local secret=$1
  local namespace=$2
  local message=$3
  local previous_force_reseal

  if ! sync_failure_needs_reseal "$message"; then
    return 1
  fi

  echo "[full-bootstrap] Repairing sealedsecret/$secret in namespace $namespace by resealing it for the current controller key"
  previous_force_reseal=$FORCE_RESEAL_SEALED_SECRET
  FORCE_RESEAL_SEALED_SECRET=$secret
  ensure_sealed_secret_manifests
  FORCE_RESEAL_SEALED_SECRET=$previous_force_reseal
}

wait_for_secret_from_sealed_secret() {
  local secret=$1
  local namespace=$2
  local description=$3
  local synced_condition
  local repair_attempted=false

  echo "[full-bootstrap] Waiting for $description"
  for _ in $(seq 1 60); do
    if kubectl get "secret/${secret}" --namespace "$namespace" >/dev/null 2>&1; then
      return 0
    fi

    synced_condition="$(kubectl get "sealedsecret/${secret}" \
      --namespace "$namespace" \
      --output "jsonpath={range .status.conditions[?(@.type=='Synced')]}{.status}{': '}{.message}{end}" 2>/dev/null || true)"
    if [ "${synced_condition#False: }" != "$synced_condition" ]; then
      if [ "$repair_attempted" = false ] && repair_sealed_secret_decryption "$secret" "$namespace" "${synced_condition#False: }"; then
        repair_attempted=true
        sleep 5
        continue
      fi

      echo "SealedSecret $namespace/$secret failed to sync: ${synced_condition#False: }" >&2
      print_sealed_secret_diagnostics "$secret" "$namespace"
      print_namespace_events "$namespace"
      echo "[full-bootstrap] Recent Sealed Secrets controller logs" >&2
      kubectl logs deployment/sealed-secrets-controller \
        --namespace kube-system \
        --tail=80 >&2 || true
      return 1
    fi

    sleep 5
  done

  echo "Timed out waiting for $description." >&2
  print_sealed_secret_diagnostics "$secret" "$namespace"
  print_namespace_events "$namespace"
  echo "[full-bootstrap] Recent Sealed Secrets controller logs" >&2
  kubectl logs deployment/sealed-secrets-controller \
    --namespace kube-system \
    --tail=80 >&2 || true
  return 1
}

print_application_diagnostics() {
  local app=$1

  echo "[full-bootstrap] Diagnostics for application/$app" >&2
  kubectl get "application/${app}" --namespace argocd --output wide >&2 || true
  kubectl describe "application/${app}" --namespace argocd >&2 || true
}

wait_for_argocd_application() {
  local app=$1
  local description=$2

  if wait_for_resource "application/${app}" argocd "$description"; then
    return 0
  fi

  print_application_diagnostics argocd-root-app
  if [ "$app" != "argocd-root-app" ]; then
    print_application_diagnostics "$app"
  fi
  echo "[full-bootstrap] Recent Argo CD events" >&2
  kubectl get events --namespace argocd --sort-by=.lastTimestamp >&2 || true
  return 1
}

seed_ldap_identity() {
  wait_for_resource deployment/ldap auth "LDAP deployment"

  echo "[full-bootstrap] Waiting for LDAP deployment"
  kubectl rollout status deployment/ldap \
    --namespace auth \
    --timeout=300s

  echo "[full-bootstrap] Seeding LDAP admin identity"
  kubectl delete job ldap-bootstrap-identity --namespace auth --ignore-not-found >/dev/null
  kubectl apply --filename - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: ldap-bootstrap-identity
  namespace: auth
spec:
  backoffLimit: 4
  template:
    spec:
      enableServiceLinks: false
      restartPolicy: OnFailure
      containers:
        - name: ldap-bootstrap-identity
          image: osixia/openldap:1.5.0
          imagePullPolicy: IfNotPresent
          env:
            - name: LDAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ldap-admin
                  key: LDAP_ADMIN_PASSWORD
            - name: BOOTSTRAP_USERNAME
              valueFrom:
                secretKeyRef:
                  name: auth-admin-user
                  key: USERNAME
            - name: BOOTSTRAP_EMAIL
              valueFrom:
                secretKeyRef:
                  name: auth-admin-user
                  key: EMAIL
            - name: BOOTSTRAP_DOMAIN
              valueFrom:
                secretKeyRef:
                  name: auth-admin-user
                  key: DOMAIN
            - name: BOOTSTRAP_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: auth-admin-user
                  key: PASSWORD
          command:
            - /bin/bash
            - -ceu
            - |
              LDAP_URI="ldap://ldap.auth.svc.cluster.local:389"
              BASE_DN="$(printf '%s' "$BOOTSTRAP_DOMAIN" | awk -F. '{ for (i = 1; i <= NF; i++) { printf "%sdc=%s", (i == 1 ? "" : ","), $i } }')"
              BIND_DN="cn=admin,${BASE_DN}"
              PEOPLE_DN="ou=people,${BASE_DN}"
              GROUPS_DN="ou=groups,${BASE_DN}"
              USER_DN="uid=${BOOTSTRAP_USERNAME},${PEOPLE_DN}"
              GROUP_DN="cn=admins,${GROUPS_DN}"

              until ldapwhoami -x -H "$LDAP_URI" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null 2>&1; do
                sleep 5
              done

              ensure_entry() {
                local dn=$1
                local ldif=$2
                if ldapsearch -x -H "$LDAP_URI" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" -b "$dn" -s base dn >/dev/null 2>&1; then
                  return 0
                fi
                printf '%s\n' "$ldif" | ldapadd -x -H "$LDAP_URI" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD"
              }

              PEOPLE_LDIF="$(printf 'dn: %s\nobjectClass: organizationalUnit\nou: people' "$PEOPLE_DN")"
              ensure_entry "$PEOPLE_DN" "$PEOPLE_LDIF"

              GROUPS_LDIF="$(printf 'dn: %s\nobjectClass: organizationalUnit\nou: groups' "$GROUPS_DN")"
              ensure_entry "$GROUPS_DN" "$GROUPS_LDIF"

              PASSWORD_HASH="$(slappasswd -s "$BOOTSTRAP_PASSWORD")"
              USER_LDIF="$(printf 'dn: %s\nobjectClass: inetOrgPerson\nobjectClass: organizationalPerson\nobjectClass: person\nobjectClass: top\nuid: %s\ncn: %s\nsn: %s\nmail: %s\nuserPassword: %s' "$USER_DN" "$BOOTSTRAP_USERNAME" "$BOOTSTRAP_USERNAME" "$BOOTSTRAP_USERNAME" "$BOOTSTRAP_EMAIL" "$PASSWORD_HASH")"
              ensure_entry "$USER_DN" "$USER_LDIF"

              GROUP_LDIF="$(printf 'dn: %s\nobjectClass: groupOfNames\ncn: admins\nmember: %s' "$GROUP_DN" "$USER_DN")"
              ensure_entry "$GROUP_DN" "$GROUP_LDIF"

              if ! ldapsearch -x -H "$LDAP_URI" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" -b "$GROUP_DN" "member=${USER_DN}" dn | grep -q "^dn:"; then
                printf 'dn: %s\nchangetype: modify\nadd: member\nmember: %s\n' "$GROUP_DN" "$USER_DN" |
                  ldapmodify -x -H "$LDAP_URI" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD"
              fi
YAML

  kubectl wait \
    --for condition=Complete \
    --namespace auth \
    --timeout=300s \
    job/ldap-bootstrap-identity
}

configure_argocd_cli() {
  if [ "$ARGOCD_CLI_LOGIN" != "true" ]; then
    echo "[full-bootstrap] Skipping Argo CD CLI login because ARGOCD_CLI_LOGIN is not true"
    return 0
  fi

  if [ "$ARGOCD_CLI_SSO" != "true" ]; then
    echo "[full-bootstrap] Skipping Argo CD CLI login because local Argo CD admin is disabled; set ARGOCD_CLI_SSO=true to log in through SSO"
    return 0
  fi

  if ! command -v argocd >/dev/null 2>&1; then
    echo "[full-bootstrap] argocd CLI not found; skipping local CLI login"
    return 0
  fi

  if ! host_resolves "$ARGOCD_CLI_SERVER"; then
    echo "[full-bootstrap] $ARGOCD_CLI_SERVER is not resolvable yet; skipping local argocd CLI login"
    return 0
  fi

  echo "[full-bootstrap] Waiting for Argo CD server deployment"
  kubectl rollout status deployment/argocd-server \
    --namespace argocd \
    --timeout=300s

  wait_for_resource ingress/argocd-server-ingress argocd "Argo CD ingress"
  kubectl wait \
    --for jsonpath='{.spec.rules[0].host}'="$ARGOCD_CLI_SERVER" \
    --namespace argocd \
    --timeout=300s \
    ingress/argocd-server-ingress

  wait_for_resource certificate/argocd-cert argocd "Argo CD TLS certificate"
  kubectl wait \
    --for condition=Ready \
    --namespace argocd \
    --timeout=300s \
    certificate/argocd-cert

  wait_for_resource ingress/auth-gateway auth "auth gateway ingress"
  wait_for_resource certificate/auth-gateway-tls auth "auth gateway TLS certificate"
  kubectl wait \
    --for condition=Ready \
    --namespace auth \
    --timeout=300s \
    certificate/auth-gateway-tls

  echo "[full-bootstrap] Waiting for auth gateway deployment"
  kubectl rollout status deployment/auth-gateway \
    --namespace auth \
    --timeout=300s

  local argocd_login_args=(--sso)

  if [ "$ARGOCD_CLI_INSECURE" = "true" ]; then
    argocd_login_args+=(--insecure)
  fi

  echo "[full-bootstrap] Logging local argocd CLI in using $ARGOCD_CLI_SERVER"
  argocd login "$ARGOCD_CLI_SERVER" \
    --grpc-web \
    "${argocd_login_args[@]}"
}

validate_argocd_bootstrap() {
  echo "[full-bootstrap] Validating Argo CD bootstrap resources"
  kubectl get application argocd-root-app --namespace argocd >/dev/null
  kubectl get secret source-repository --namespace argocd >/dev/null

  if command -v argocd >/dev/null 2>&1 && [ "$ARGOCD_CLI_LOGIN" = "true" ]; then
    if ! host_resolves "$ARGOCD_CLI_SERVER"; then
      echo "[full-bootstrap] Skipping argocd CLI validation because $ARGOCD_CLI_SERVER is not resolvable"
      return 0
    fi

    echo "[full-bootstrap] Validating Argo CD root app and repository through argocd CLI"
    argocd app get argocd-root-app --grpc-web >/dev/null
    argocd repo get https://github.com/kyle-blair/homelab-cluster.git --grpc-web >/dev/null
  fi
}

print_bootstrap_summary() {
  mkdir -p "$ARTIFACTS_DIR"

  local username
  local password
  username="$(get_secret_value auth auth-admin-user USERNAME)"
  password="$(get_secret_value auth auth-admin-user PASSWORD)"

  local ingress_ip
  ingress_ip="$(kubectl get service ingress-nginx-controller \
    --namespace ingress-nginx \
    --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -z "$ingress_ip" ]; then
    ingress_ip="$(kubectl get service ingress-nginx-controller \
      --namespace ingress-nginx \
      --output jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  fi

  cat >"${ARTIFACTS_DIR}/bootstrap-credentials.txt" <<SUMMARY
Cluster access
==============

Auth gateway URL: https://auth.${CLUSTER_DOMAIN}
Argo CD URL:      https://argocd.${CLUSTER_DOMAIN}
Observability URL: https://observability.${CLUSTER_DOMAIN}
Metrics URL:       https://metrics.${CLUSTER_DOMAIN}
Alerts URL:        https://alerts.${CLUSTER_DOMAIN}

Admin user:       ${username}
Admin password:   ${password}

Root CA:          ${ARTIFACTS_DIR}/internal-ca.crt
Ingress address:  ${ingress_ip:-not assigned yet}
DNS records:      Point auth, argocd, observability, metrics, and alerts at the ingress address.
SUMMARY

  chmod 0600 "${ARTIFACTS_DIR}/bootstrap-credentials.txt"
  echo "[full-bootstrap] Wrote cluster access details to ${ARTIFACTS_DIR}/bootstrap-credentials.txt"
}

if [ "$PROVISION_CLUSTER" = true ]; then
  validate_inputs
  configure_repo_manifests
  run_kubespray
else
  validate_inputs
  configure_repo_manifests
  echo "[full-bootstrap] Skipping Kubespray; pass --provision-cluster to build the cluster first"
fi

wait_for_api
bootstrap_argocd
wait_for_sealed_secrets
ensure_sealed_secret_manifests
wait_for_secret_from_sealed_secret internal-ca cert-manager "cert-manager internal CA secret"
wait_for_secret_from_sealed_secret ldap-admin auth "LDAP admin secret"
wait_for_secret_from_sealed_secret auth-gateway-secrets auth "auth gateway secret"
wait_for_secret_from_sealed_secret auth-admin-user auth "auth admin user secret"
seed_ldap_identity
configure_argocd_cli
validate_argocd_bootstrap
print_bootstrap_summary

echo "[full-bootstrap] Bootstrap complete."
