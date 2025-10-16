#!/usr/bin/env bash
# teardown.sh
# Fully tears down the single-node lab stack (Kubernetes, Splunk/Cribl, Redis, Docker/containerd) on THIS VM.
# Usage:
#   sudo bash teardown.sh
#   sudo bash teardown.sh --force   # skip confirmation

set -euo pipefail

confirm() {
  if [[ "${FORCE:-0}" == "1" ]]; then return 0; fi
  read -r -p "This will tear down Kubernetes, Splunk/Cribl, Redis, Docker/containerd, and related files on THIS VM. Continue? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf "\n\033[1;36m[%s]\033[0m %s\n" "$(date +'%F %T')" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
run()  { echo "+ $*"; eval "$@" || true; }

require_sudo() {
  if [[ $EUID -ne 0 ]]; then
    warn "Not running as root. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

main() {
  FORCE=0
  [[ "${1:-}" == "--force" ]] && FORCE=1
  export FORCE

  require_sudo "$@"
  confirm || { warn "Aborted."; exit 1; }

  # Prefer azureuser kubeconfig if present
  export KUBECONFIG=${KUBECONFIG:-/home/azureuser/.kube/config}
  [[ -f "$KUBECONFIG" ]] || unset KUBECONFIG

  # Short kubectl timeouts so we never hang on a dead API/finalizers
  KCTL="kubectl --request-timeout=10s"
  KWAIT="--wait=false --ignore-not-found"

  NS_SPLUNK="splunk-operator"
  NS_CRIBL="cribl-stream"

  log "Uninstalling Helm releases (best-effort, non-blocking)..."
  if have helm; then
    run "helm uninstall splunk-standalone -n ${NS_SPLUNK} 2>/dev/null || true"
    run "helm uninstall ls-leader -n ${NS_CRIBL} 2>/dev/null || true"
    run "helm uninstall ls-wg1 -n ${NS_CRIBL} 2>/dev/null || true"
  fi

  # Only do kubectl work if the API responds quickly
  if have kubectl && ${KCTL} version >/dev/null 2>&1; then
    log "Deleting Splunk/Cribl namespaces (no wait, short timeout)..."
    run "${KCTL} delete ns ${NS_SPLUNK} ${NS_CRIBL} ${KWAIT}"

    log "Removing addons (metrics-server, local-path-provisioner)..."
    run "${KCTL} -n kube-system delete deploy metrics-server ${KWAIT}"
    run "${KCTL} delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml ${KWAIT}"

    log "Deleting PVCs/PVs cluster-wide (no wait)..."
    run "${KCTL} delete pvc --all --all-namespaces ${KWAIT}"
    run "${KCTL} delete pv --all ${KWAIT}"

    # Try to remove Splunk Operator CRDs so kubectl doesn't hang on them later
    log "Deleting Splunk Operator CRDs (if present)..."
    run "${KCTL} get crd -o name 2>/dev/null | grep -E 'splunk|enterprise\.splunk\.com' | xargs -r ${KCTL} delete ${KWAIT}"

    # If jq is present, try to nuke finalizers on stuck PVC/PV to avoid Terminating hangs
    if have jq; then
      log "Clearing finalizers for stuck PVC/PV objects (best-effort)..."
      run "${KCTL} get pvc --all-namespaces -o json \
        | jq '.items[] | select(.metadata.deletionTimestamp!=null) | .metadata.finalizers=null' \
        | ${KCTL} replace -f - 2>/dev/null || true"
      run "${KCTL} get pv -o json \
        | jq '.items[] | select(.metadata.deletionTimestamp!=null) | .metadata.finalizers=null' \
        | ${KCTL} replace -f - 2>/dev/null || true"
    else
      warn "jq not found; skipping finalizer cleanup for stuck objects."
    fi
  else
    warn "Kubernetes API not reachable quickly; skipping kubectl resource cleanup."
  fi

  log "Stopping services (kubelet, docker, containerd, redis)..."
  run "systemctl stop kubelet 2>/dev/null"
  run "systemctl stop docker 2>/dev/null"
  run "systemctl stop containerd 2>/dev/null"
  run "systemctl stop redis-server 2>/dev/null"

  log "kubeadm reset (flush iptables, CNI, etc.)..."
  if have kubeadm; then
    run "kubeadm reset -f"
  else
    warn "kubeadm not found; skipping kubeadm reset."
  fi

  log "Removing Kubernetes data & config..."
  run "rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /var/lib/cni /run/flannel"
  run "rm -rf /root/.kube /home/*/.kube"
  run "rm -rf /etc/cni/net.d /opt/cni/bin"

  log "Remove Splunk Universal Forwarder (if installed)..."
  run "systemctl stop splunkforwarder 2>/dev/null"
  run "rm -rf /opt/splunkforwarder"
  if getent passwd splunk >/dev/null 2>&1; then
    run "userdel -r splunk 2>/dev/null"
  fi
  if getent group splunk >/dev/null 2>&1; then
    run "groupdel splunk 2>/dev/null"
  fi

  log "Re-enable swap and restore sysctl (if previously changed)..."
  # Un-comment swap lines we commented before
  run "sed -i 's/^#\\(.*\\sswap\\s.*\\)/\\1/' /etc/fstab || true"
  run "swapon -a || true"
  # Remove our k8s sysctl drop-in if present
  if [[ -f /etc/sysctl.d/k8s.conf ]]; then
    run "rm -f /etc/sysctl.d/k8s.conf"
  fi
  run "sysctl --system || true"

  log "Remove containerd (binaries, config, systemd unit)..."
  run "systemctl disable containerd 2>/dev/null"
  run "rm -f /usr/local/lib/systemd/system/containerd.service /etc/systemd/system/containerd.service"
  run "systemctl daemon-reload"
  run "rm -rf /etc/containerd /var/lib/containerd /usr/local/sbin/runc /usr/local/bin/ctr /usr/local/bin/containerd*"

  log "Docker cleanup..."
  run "systemctl disable docker 2>/dev/null"
  run "rm -rf /var/lib/docker /etc/docker /var/run/docker.sock"
  if have docker; then
    run "docker system prune -af 2>/dev/null"
    run "docker volume prune -f 2>/dev/null"
  fi

  log "Uninstall packages (kubelet/kubeadm/kubectl, docker.io, redis-server; remove helm binary if present)..."
  run "apt-mark unhold kubelet kubeadm kubectl 2>/dev/null"
  run "apt purge -y kubelet kubeadm kubectl docker.io redis-server 2>/dev/null"
  run "apt autoremove -y 2>/dev/null"
  if [[ -f /usr/local/bin/helm ]]; then
    run "rm -f /usr/local/bin/helm"
  fi

  log "Clean iptables/ipvs rules (kubeadm reset usually covers this)..."
  run "iptables -F 2>/dev/null"
  run "iptables -t nat -F 2>/dev/null"
  run "iptables -t mangle -F 2>/dev/null"
  run "iptables -X 2>/dev/null"
  run "ipvsadm --clear 2>/dev/null || true"

  log "Revert Redis changes (restore most recent /etc/redis/redis.conf backup if found)..."
  LATEST_BAK="$(ls -1t /etc/redis/redis.conf.bak_* 2>/dev/null | head -n1 || true)"
  if [[ -n "${LATEST_BAK}" && -f "${LATEST_BAK}" ]]; then
    run "cp -f '${LATEST_BAK}' /etc/redis/redis.conf"
  fi

  log "Remove artifacts and manifests created by the setup script..."
  run "rm -f /home/azureuser/get_helm.sh"
  run "rm -f /home/azureuser/idx.yml /home/azureuser/idx-node-ports.yml /home/azureuser/sh.yml"
  run "rm -f /home/azureuser/fixed-pvc.yml /home/azureuser/cribl-leader.yml /home/azureuser/cribl-wg1.yml"
  run "rm -f /home/azureuser/password.txt /home/azureuser/services.txt"
  run "rm -f /home/azureuser/post_deploy_info.sh"
  run "rm -f /home/azureuser/timer.txt /home/azureuser/how_long.txt"

  log "Final apt metadata refresh (optional)..."
  run "apt update -y 2>/dev/null || true"

  log "Done. A reboot is recommended: sudo reboot"
}

main "$@"