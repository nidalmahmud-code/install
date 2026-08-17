#!/usr/bin/env bash
#
#  Invicti Platform on-premises, unattended install on a clean Ubuntu Server.
#  ---------------------------------------------------------------------------
#  Checks every prerequisite first, installs what it can, and refuses to start a
#  30 minute deployment that is going to fail. Written from the failures seen on
#  a real lab build: Helm 4 conflicts with KEDA, the production resource profile
#  will not schedule on one node, and Ubuntu's guided LVM install leaves most of
#  the disk unallocated so pods fail on ephemeral-storage.
#
#  Usage
#    bash invicti-onprem-setup.sh                 install (prompts for credentials)
#    bash invicti-onprem-setup.sh --check         run every check, change nothing
#    bash invicti-onprem-setup.sh --uninstall     remove the release and namespace
#    bash invicti-onprem-setup.sh --help
#
#  Unattended
#    INVICTI_EMAIL=you@invicti.com INVICTI_LICENSE_KEY=XXXX-XXXX \
#    PLATFORM_HOST=invicti.lab bash invicti-onprem-setup.sh
#
#  Overrides
#    PLATFORM_HOST=invicti.lab     hostname the platform is published under
#    HELM_VERSION=v3.16.4          Helm 3 release. Never use Helm 4, see notes below.
#    RESOURCE_PROFILE=<path>       force a specific values-resources-*.yaml
#    AUTO_FALLBACK=true            on unschedulable pods, retry once with the
#                                  'none' profile (no requests or limits)
#    MIN_MEM_GI=12                 hard floor, abort below this
#    WANT_MEM_GI=20                soft floor for a single-node cluster, warn below
#    EXPAND_DISK=true              grow the root LV into free VG space
#    WAIT_MINUTES=30               how long to wait for pods to settle
#    SKIP_UPGRADE=false            skip apt full-upgrade
#    FORCE=false                    proceed despite hard-floor failures
#
set -euo pipefail

VERSION="2.0"

# ---------------------------------------------------------------- settings

PLATFORM_HOST="${PLATFORM_HOST:-invicti.lab}"
NAMESPACE="${NAMESPACE:-invicti}"
RELEASE="${RELEASE:-invicti-platform}"
CHART="oci://platform-registry.invicti.com/invicti-platform-helm-charts/onpremises"
REGISTRY="platform-registry.invicti.com"
HELM_VERSION="${HELM_VERSION:-v3.16.4}"
HELM_TIMEOUT="${HELM_TIMEOUT:-30m}"
WAIT_MINUTES="${WAIT_MINUTES:-30}"
MIN_CPU="${MIN_CPU:-6}"
MIN_MEM_GI="${MIN_MEM_GI:-12}"
WANT_MEM_GI="${WANT_MEM_GI:-20}"
MIN_DISK_GI="${MIN_DISK_GI:-50}"
WANT_DISK_GI="${WANT_DISK_GI:-150}"
EXPAND_DISK="${EXPAND_DISK:-true}"
AUTO_FALLBACK="${AUTO_FALLBACK:-true}"
SKIP_UPGRADE="${SKIP_UPGRADE:-false}"
FORCE="${FORCE:-false}"
RESOURCE_PROFILE="${RESOURCE_PROFILE:-}"
MODE="install"

WARNINGS=0
FAILURES=0

# ---------------------------------------------------------------- plumbing

# Run as your normal user (the script sudos itself) or under sudo. Either way the
# workdir, kubeconfig and logs end up owned by the human, not root.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  TARGET_USER="$SUDO_USER"
  TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  TARGET_USER="$(id -un)"
  TARGET_HOME="$HOME"
fi
WORKDIR="${WORKDIR:-$TARGET_HOME/invicti-onprem}"
LOGFILE="${LOGFILE:-$TARGET_HOME/invicti-install-$(date +%Y%m%d-%H%M%S).log}"

c_head=$'\033[1;35m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'
c_err=$'\033[1;31m';  c_dim=$'\033[2m';   c_off=$'\033[0m'

log()  { printf '\n%s==> %s%s\n' "$c_head" "$*" "$c_off"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s[ok]%s   %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_warn" "$c_off" "$*"; WARNINGS=$((WARNINGS+1)); }
bad()  { printf '%s[fail]%s %s\n' "$c_err" "$c_off" "$*"; FAILURES=$((FAILURES+1)); }
die()  { printf '\n%s[x] %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
hint() { printf '%s        %s%s\n' "$c_dim" "$*" "$c_off"; }

on_err() {
  local line=$1 code=$2
  printf '\n%s[x] Failed at line %s (exit %s).%s\n' "$c_err" "$line" "$code" "$c_off" >&2
  printf '    Log: %s\n' "$LOGFILE" >&2
  printf '    The script is idempotent. Fix the cause and run it again.\n' >&2
}
trap 'on_err "$LINENO" "$?"' ERR

usage() { sed -n '2,32p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; }

case "${1:-}" in
  --help|-h)   usage; exit 0 ;;
  --check)     MODE="check" ;;
  --uninstall) MODE="uninstall" ;;
  "")          ;;
  *)           die "Unknown argument '$1'. Try --help." ;;
esac

exec > >(tee -a "$LOGFILE") 2>&1

printf '%s\n' "Invicti Platform on-premises setup, v${VERSION}  (mode: ${MODE})"
printf '%s\n' "Log: ${LOGFILE}"

# ---------------------------------------------------------------- uninstall

if [[ "$MODE" == "uninstall" ]]; then
  export KUBECONFIG="${KUBECONFIG:-$TARGET_HOME/.kube/config}"
  log "Removing release '${RELEASE}' and namespace '${NAMESPACE}'"
  helm uninstall "$RELEASE" -n "$NAMESPACE" || warn "Release not found."
  kubectl delete namespace "$NAMESPACE" --timeout=300s || warn "Namespace absent or slow to delete."
  ok "Done. k3s and Helm were left in place, so a re-install is quick."
  hint "If the namespace sticks in Terminating: kubectl get all -n ${NAMESPACE}"
  exit 0
fi

# ================================================================ phase 1
#                                                        system requirements

log "Phase 1: system requirements"

[[ "$(uname -s)" == "Linux" ]] || die "Linux only."
[[ "$(uname -m)" == "x86_64" ]] || warn "Architecture $(uname -m) is untested, x86_64 expected."
grep -qi microsoft /proc/version 2>/dev/null && warn "Running under WSL. Use the Windows installer for WSL, not this script."

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "OS: ${PRETTY_NAME:-unknown}"
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "Not Ubuntu. Should work on any systemd distro with apt, but untested."
  else
    ok "Ubuntu detected."
  fi
fi

command -v sudo >/dev/null || die "sudo is required."
sudo -v || die "sudo authentication failed."
ok "sudo available."

# --- cpu
CPUS="$(nproc)"
if (( CPUS >= MIN_CPU )); then
  ok "CPU cores: ${CPUS} (minimum ${MIN_CPU})"
else
  bad "CPU cores: ${CPUS}, documented minimum is ${MIN_CPU}."
  hint "Shut the VM down, then on the Hyper-V host:"
  hint "  Set-VMProcessor -VMName \"<vm>\" -Count ${MIN_CPU}"
fi

# --- memory
MEM_GI="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)"
if (( MEM_GI >= WANT_MEM_GI )); then
  ok "Memory: ${MEM_GI} GB (comfortable for a single-node cluster)"
elif (( MEM_GI >= MIN_MEM_GI )); then
  warn "Memory: ${MEM_GI} GB. Meets the documented ${MIN_MEM_GI} GB minimum, but that figure assumes a multi-node cluster."
  hint "On one node the platform plus k3s needs closer to ${WANT_MEM_GI} GB. Pods may stay Pending."
  hint "  Set-VMMemory -VMName \"<vm>\" -StartupBytes ${WANT_MEM_GI}GB"
else
  bad "Memory: ${MEM_GI} GB, below the documented ${MIN_MEM_GI} GB minimum."
  hint "  Set-VMMemory -VMName \"<vm>\" -StartupBytes ${WANT_MEM_GI}GB"
fi

# --- disk, and reclaim the rest of the volume group if Ubuntu left it unused.
#     The guided LVM installer typically allocates only ~half the disk, which
#     caps the node's ephemeral-storage allocatable and makes pods unschedulable
#     even though df shows plenty free.
disk_free_gi() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }
disk_size_gi() { df -BG --output=size / | tail -1 | tr -dc '0-9'; }

info "Root filesystem: $(disk_size_gi) GB total, $(disk_free_gi) GB free"

if command -v vgs >/dev/null 2>&1; then
  VG_FREE_G="$(sudo vgs --noheadings -o vg_free --units g 2>/dev/null | tr -dc '0-9.' | cut -d. -f1 || true)"
  ROOT_LV="$(findmnt -no SOURCE / || true)"
  if [[ -n "${VG_FREE_G:-}" && "$VG_FREE_G" =~ ^[0-9]+$ ]] && (( VG_FREE_G > 5 )) && [[ "$ROOT_LV" == /dev/mapper/* ]]; then
    if [[ "$EXPAND_DISK" == "true" && "$MODE" == "install" ]]; then
      log "Reclaiming ${VG_FREE_G} GB of unallocated volume group space"
      sudo lvextend -r -l +100%FREE "$ROOT_LV"
      ok "Root filesystem is now $(disk_size_gi) GB, $(disk_free_gi) GB free"
    else
      warn "${VG_FREE_G} GB of the volume group is unallocated (Ubuntu's guided LVM default)."
      hint "This caps node ephemeral-storage and causes unschedulable pods. Fix with:"
      hint "  sudo lvextend -r -l +100%FREE ${ROOT_LV}"
    fi
  fi
fi

DISK_GI="$(disk_free_gi)"
if (( DISK_GI >= WANT_DISK_GI )); then
  ok "Free disk: ${DISK_GI} GB"
elif (( DISK_GI >= MIN_DISK_GI )); then
  warn "Free disk: ${DISK_GI} GB. Meets the documented ${MIN_DISK_GI} GB minimum but is tight once images and scan data land."
else
  bad "Free disk: ${DISK_GI} GB, below the documented ${MIN_DISK_GI} GB minimum."
fi

# --- ports k3s ingress needs
for port in 80 443; do
  if sudo ss -lnt "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
    if sudo ss -lntp "sport = :${port}" 2>/dev/null | grep -qE 'k3s|traefik|svclb'; then
      ok "Port ${port} held by k3s, expected on a re-run."
    else
      bad "Port ${port} is already in use by something other than k3s."
      hint "  sudo ss -lntp 'sport = :${port}'"
    fi
  else
    ok "Port ${port} free."
  fi
done

# --- outbound connectivity. /v2/ answers 401 unauthenticated, so any HTTP
#     status means reachable; only a total failure returns 000.
http_reachable() {
  local url="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" || echo 000)"
  [[ "$code" != "000" ]] && printf '%s' "$code"
}
for target in "https://get.k3s.io" "https://${REGISTRY}/v2/" "https://registry-1.docker.io/v2/"; do
  if code="$(http_reachable "$target")"; then
    ok "Reachable: ${target} (HTTP ${code})"
  else
    bad "Unreachable: ${target}"
    hint "Behind a proxy? Export the proxy variables, then re-run:"
    hint "  export https_proxy=http://proxy:8080 http_proxy=http://proxy:8080"
    hint "  export no_proxy=localhost,127.0.0.1,.svc,.cluster.local"
  fi
done

# --- verdict
log "Requirements summary"
info "Failures: ${FAILURES}   Warnings: ${WARNINGS}"
if (( FAILURES > 0 )); then
  if [[ "$FORCE" == "true" ]]; then
    warn "Continuing despite ${FAILURES} failure(s) because FORCE=true."
  else
    die "${FAILURES} requirement(s) not met. Fix the items marked [fail], or re-run with FORCE=true to try anyway."
  fi
else
  ok "All hard requirements met."
fi

if [[ "$MODE" == "check" ]]; then
  log "Check mode, nothing was installed."
  exit $(( FAILURES > 0 ? 1 : 0 ))
fi

# ================================================================ phase 2
#                                                            credentials

log "Phase 2: credentials"
INVICTI_EMAIL="${INVICTI_EMAIL:-}"
INVICTI_LICENSE_KEY="${INVICTI_LICENSE_KEY:-}"
[[ -n "$INVICTI_EMAIL" ]] || read -rp "    Invicti account email: " INVICTI_EMAIL
if [[ -z "$INVICTI_LICENSE_KEY" ]]; then
  read -rsp "    Invicti license key (hidden): " INVICTI_LICENSE_KEY; echo
fi
[[ -n "$INVICTI_EMAIL" && -n "$INVICTI_LICENSE_KEY" ]] || die "Email and license key are both required."
ok "Credentials captured. Hostname: ${PLATFORM_HOST}"

# ================================================================ phase 3
#                                                          packages, OS

log "Phase 3: base packages"

# A freshly booted Ubuntu runs unattended-upgrades and cloud-init, both of which
# hold the dpkg lock. Wait rather than failing.
wait_for_apt() {
  local waited=0
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    (( waited == 0 )) && info "Waiting for another apt process to finish ..."
    sleep 5; waited=$((waited+5))
    (( waited > 600 )) && die "apt has been locked for 10 minutes. Check: ps aux | grep -E 'apt|unattended'"
  done
}

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

wait_for_apt
sudo apt-get update -qq
if [[ "$SKIP_UPGRADE" != "true" ]]; then
  info "Applying OS updates, this can take a few minutes ..."
  wait_for_apt
  sudo apt-get "${APT_OPTS[@]}" full-upgrade
else
  info "Skipped full-upgrade (SKIP_UPGRADE=true)."
fi
wait_for_apt
sudo apt-get "${APT_OPTS[@]}" install curl tar ca-certificates open-iscsi lvm2
ok "Base packages present."
if [[ -f /var/run/reboot-required ]]; then
  warn "A reboot is pending from the OS update. Continuing, but reboot when convenient."
fi

# ================================================================ phase 4
#                                                                    k3s

log "Phase 4: k3s"

if command -v k3s >/dev/null && sudo systemctl is-active --quiet k3s; then
  ok "k3s already installed and running."
else
  # Pass any proxy settings through to the k3s service, otherwise image pulls
  # fail on a proxied network even though the shell can reach the registry.
  if [[ -n "${https_proxy:-${HTTPS_PROXY:-}}" ]]; then
    info "Proxy detected, writing /etc/systemd/system/k3s.service.env"
    sudo tee /etc/systemd/system/k3s.service.env >/dev/null <<EOF
HTTP_PROXY=${http_proxy:-${HTTP_PROXY:-}}
HTTPS_PROXY=${https_proxy:-${HTTPS_PROXY:-}}
NO_PROXY=${no_proxy:-localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}
EOF
  fi
  info "Installing k3s ..."
  curl -sfL https://get.k3s.io | sudo sh -
  ok "k3s installed."
fi
hash -r

log "Phase 4b: kubeconfig for ${TARGET_USER}"
sudo mkdir -p "$TARGET_HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$TARGET_HOME/.kube/config"
sudo chown -R "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$TARGET_HOME/.kube"
sudo chmod 600 "$TARGET_HOME/.kube/config"
export KUBECONFIG="$TARGET_HOME/.kube/config"
if ! sudo grep -q 'KUBECONFIG' "$TARGET_HOME/.bashrc" 2>/dev/null; then
  echo 'export KUBECONFIG=$HOME/.kube/config' | sudo tee -a "$TARGET_HOME/.bashrc" >/dev/null
fi
ok "kubeconfig in place. New shells get it automatically."
hint "For this shell after the script exits: export KUBECONFIG=\$HOME/.kube/config"

info "Waiting for the node to become Ready ..."
for i in $(seq 1 72); do
  if kubectl get nodes 2>/dev/null | grep -qw ' Ready'; then break; fi
  if (( i == 72 )); then die "Node not Ready after 6 minutes. Check: sudo journalctl -u k3s -e"; fi
  sleep 5
done
kubectl get nodes -o wide
ok "Cluster responding."

# ================================================================ phase 5
#                                                                 Helm 3
#
# Helm 4 must not be used. It applies resources server-side, so it fights KEDA
# for ownership of ScaledJob container resource fields and the deploy dies with
#   conflict occurred while applying object invicti/dast-scanner ...
#   conflicts with "keda" using keda.sh/v1alpha1
# The docs list Helm 3.8+ as supported. Ubuntu's snap 'helm' package is Helm 4,
# so it is removed here if present.

log "Phase 5: Helm 3"

helm_major() { helm version --short 2>/dev/null | grep -oE 'v[0-9]+' | head -1 | tr -d 'v'; }

CUR_MAJOR=""
if command -v helm >/dev/null; then CUR_MAJOR="$(helm_major || true)"; fi

if [[ "$CUR_MAJOR" == "3" ]]; then
  ok "Helm $(helm version --short) already present."
else
  if [[ -n "$CUR_MAJOR" ]]; then
    warn "Helm ${CUR_MAJOR} found. It is incompatible with this chart, replacing it with Helm ${HELM_VERSION}."
  fi
  if command -v snap >/dev/null && snap list helm >/dev/null 2>&1; then
    info "Removing the snap helm package (it ships Helm 4)."
    sudo snap remove helm
  fi
  info "Installing Helm ${HELM_VERSION} ..."
  curl -fsSL -o /tmp/get-helm-3.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod +x /tmp/get-helm-3.sh
  sudo DESIRED_VERSION="$HELM_VERSION" /tmp/get-helm-3.sh
  hash -r
  [[ "$(helm_major)" == "3" ]] || die "Still on Helm $(helm version --short). Check PATH order, /usr/local/bin must come before /snap/bin."
  ok "Helm $(helm version --short) installed."
fi

log "Phase 5b: cluster prerequisites"
kubectl version 2>/dev/null | grep -i 'server version' || true
if kubectl get storageclass -o jsonpath='{.items[*].metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null | grep -q true; then
  ok "Default StorageClass present."
  kubectl get storageclass
else
  die "No default StorageClass. k3s normally provides local-path. Check: kubectl get storageclass"
fi

# ================================================================ phase 6
#                                                     chart and profile

log "Phase 6: chart"

info "Authenticating to ${REGISTRY} (the password is your license key) ..."
printf '%s' "$INVICTI_LICENSE_KEY" | helm registry login "$REGISTRY" \
  --username "$INVICTI_EMAIL" --password-stdin
ok "Registry login succeeded."

sudo mkdir -p "$WORKDIR"
sudo chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$WORKDIR"
cd "$WORKDIR"
rm -rf onpremises onpremises-*.tgz
info "Pulling the chart into ${WORKDIR} ..."
helm pull "$CHART"
tar xf onpremises-*.tgz
ok "Chart extracted."

log "Phase 6b: resource profile"
#
# Two naming schemes exist in the wild:
#   size-tagged   values-resources-recommended-12gi.yaml
#   named         values-resources-basic.yaml / -none.yaml / -recommended.yaml
# 'recommended' is production-sized and will leave most pods Pending on a single
# node, so it is only chosen on a large machine.

mapfile -t PROFILES < <(find "$WORKDIR/onpremises" -maxdepth 2 -name 'values-resources-*.yaml' | sort)
(( ${#PROFILES[@]} > 0 )) || die "No values-resources-*.yaml in the chart. Chart layout changed, inspect ${WORKDIR}/onpremises."
info "Profiles shipped in this chart:"
for p in "${PROFILES[@]}"; do info "  - $(basename "$p")"; done

P_BASIC="";  P_NONE="";  P_RECOMMENDED=""
for p in "${PROFILES[@]}"; do
  case "$(basename "$p")" in
    values-resources-basic.yaml)       P_BASIC="$p" ;;
    values-resources-none.yaml)        P_NONE="$p" ;;
    values-resources-recommended.yaml) P_RECOMMENDED="$p" ;;
  esac
done

if [[ -n "$RESOURCE_PROFILE" ]]; then
  [[ -f "$RESOURCE_PROFILE" ]] || die "RESOURCE_PROFILE not found: ${RESOURCE_PROFILE}"
  info "Forced by RESOURCE_PROFILE."
else
  BUDGET_GI=$(( MEM_GI - 3 ))
  (( BUDGET_GI < 1 )) && BUDGET_GI=1
  BEST=0
  for p in "${PROFILES[@]}"; do
    size="$(basename "$p" | grep -oiE '[0-9]+gi' | grep -oE '[0-9]+' | head -1 || true)"
    [[ -z "$size" ]] && continue
    if (( size <= BUDGET_GI && size > BEST )); then BEST="$size"; RESOURCE_PROFILE="$p"; fi
  done
  if [[ -n "$RESOURCE_PROFILE" ]]; then
    info "Size-tagged profile fitting ${BUDGET_GI} Gi: ${BEST}gi"
  elif (( MEM_GI >= 24 )) && [[ -n "$P_RECOMMENDED" ]]; then
    RESOURCE_PROFILE="$P_RECOMMENDED"
    info "${MEM_GI} Gi node, using 'recommended'."
  elif [[ -n "$P_BASIC" ]]; then
    RESOURCE_PROFILE="$P_BASIC"
    info "${MEM_GI} Gi node, using 'basic'."
  elif [[ -n "$P_RECOMMENDED" ]]; then
    RESOURCE_PROFILE="$P_RECOMMENDED"
    warn "Only 'recommended' available, which is production-sized."
  else
    RESOURCE_PROFILE="${PROFILES[0]}"
    warn "No profile recognised by name, using $(basename "$RESOURCE_PROFILE")."
  fi
fi
ok "Profile: $(basename "$RESOURCE_PROFILE")"

log "Phase 6c: values.yaml"
umask 077
cat > "$WORKDIR/values.yaml" <<EOF
global:
  email_address: ${INVICTI_EMAIL}
  license_key: ${INVICTI_LICENSE_KEY}
  app:
    web_application_host: ${PLATFORM_HOST}
EOF
umask 022
chmod 600 "$WORKDIR/values.yaml"
ok "${WORKDIR}/values.yaml written, mode 600. It holds the license key, redact before sharing."

# Resolve the platform hostname locally so curl checks and any in-VM browsing work.
if ! grep -qE "[[:space:]]${PLATFORM_HOST}([[:space:]]|$)" /etc/hosts; then
  echo "127.0.0.1    ${PLATFORM_HOST}" | sudo tee -a /etc/hosts >/dev/null
  ok "Added '${PLATFORM_HOST}' to /etc/hosts."
fi

# ================================================================ phase 7
#                                                                 deploy

not_ready() {
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '
    $3 == "Completed" || $3 == "Succeeded" { next }
    { split($2, r, "/"); if ($3 != "Running" || r[1] != r[2]) print }'
}

sched_failures() {
  kubectl get events -n "$NAMESPACE" --field-selector reason=FailedScheduling \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null \
    | grep -Eio 'insufficient (cpu|memory|ephemeral-storage)' | sort -u || true
}

deploy() {
  local profile="$1"
  log "Deploying with $(basename "$profile")"
  # No --wait on purpose. Helm would sit silently for the whole timeout while
  # pods stay Pending; polling ourselves surfaces the reason in minutes.
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --values "$profile" \
    --values "$WORKDIR/values.yaml" \
    --timeout "$HELM_TIMEOUT"
}

# 0 = all ready, 1 = unschedulable, 2 = timed out
settle() {
  local deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
  local grace=$(( $(date +%s) + 240 ))
  local pending total bad fails
  while (( $(date +%s) < deadline )); do
    pending="$(not_ready)"
    [[ -z "$pending" ]] && { echo; return 0; }
    total="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)"
    bad="$(printf '%s\n' "$pending" | grep -c . || true)"
    printf '\r    %s/%s pods ready, %s starting ...      ' "$(( total - bad ))" "$total" "$bad"
    if (( $(date +%s) > grace )); then
      fails="$(sched_failures)"
      if [[ -n "$fails" ]]; then
        echo
        warn "Pods cannot be scheduled. Shortages reported: $(echo "$fails" | paste -sd', ')"
        return 1
      fi
    fi
    sleep 15
  done
  echo
  return 2
}

deploy "$RESOURCE_PROFILE"
set +e
settle; SETTLE=$?
set -e

if (( SETTLE == 1 )) && [[ "$AUTO_FALLBACK" == "true" ]] \
   && [[ -n "$P_NONE" && "$RESOURCE_PROFILE" != "$P_NONE" ]]; then
  warn "Retrying once with the 'none' profile, which sets no requests or limits."
  hint "Every pod will schedule, but nothing protects the node from OOM. Acceptable for a lab, not for production."
  RESOURCE_PROFILE="$P_NONE"
  deploy "$RESOURCE_PROFILE"
  set +e
  settle; SETTLE=$?
  set -e
fi

# ================================================================ phase 8
#                                                     verify and report

log "Phase 8: verification"
kubectl get pods -n "$NAMESPACE"

case "$SETTLE" in
  0) ok "Every pod is Running or Completed." ;;
  1) warn "Some pods remain unschedulable:"
     not_ready | sed 's/^/        /'
     hint "This node is short on resources for the platform. From the Hyper-V host, VM shut down:"
     hint "  Set-VMMemory    -VMName \"<vm>\" -StartupBytes 24GB"
     hint "  Set-VMProcessor -VMName \"<vm>\" -Count 12"
     hint "Then re-run this script, it will upgrade the existing release in place."
     ;;
  2) warn "Not everything was ready within ${WAIT_MINUTES} minutes. Outstanding:"
     not_ready | sed 's/^/        /'
     hint "kubectl describe pod -n ${NAMESPACE} <pod> | tail -20"
     hint "kubectl logs -n ${NAMESPACE} <pod> --previous --tail=50"
     hint "kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -30"
     ;;
esac

log "Phase 8b: reachability"
HTTP_CODE=000
for _ in 1 2 3 4 5 6; do
  HTTP_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 20 "https://${PLATFORM_HOST}/" || echo 000)"
  [[ "$HTTP_CODE" =~ ^(200|301|302|307)$ ]] && break
  sleep 20
done
if [[ "$HTTP_CODE" =~ ^(200|301|302|307)$ ]]; then
  ok "Platform answered HTTP ${HTTP_CODE} on https://${PLATFORM_HOST}/"
else
  warn "Platform returned '${HTTP_CODE}'. If pods are still starting, retry in a few minutes:"
  hint "curl -k -I https://${PLATFORM_HOST}/"
fi

VM_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"

cat <<EOF

${c_ok}Finished.${c_off}

  Profile used   : $(basename "$RESOURCE_PROFILE")
  Namespace      : ${NAMESPACE}
  Release        : ${RELEASE}
  Warnings       : ${WARNINGS}
  Log            : ${LOGFILE}

To reach the dashboard from Windows, add this to
C:\\Windows\\System32\\drivers\\etc\\hosts (elevated editor):

    ${VM_IP}    ${PLATFORM_HOST}

then open  https://${PLATFORM_HOST}
The default certificate is self-signed, so expect a browser warning.

  export KUBECONFIG=\$HOME/.kube/config
  kubectl get pods -n ${NAMESPACE}
  helm status ${RELEASE} -n ${NAMESPACE}
  bash \$0 --check       re-run the requirement checks only
  bash \$0 --uninstall   remove the release and namespace

EOF
