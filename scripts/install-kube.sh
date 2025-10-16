#!/bin/bash
set -euo pipefail

# Log time started
echo "Script started: $(date)" > /home/azureuser/timer.txt

# ===============================
# CONTROLLER NODE SETUP
# ===============================

echo
echo "INSTALLING DEPENDENCIES"
echo "-----------------------------------------------------------------"
sudo apt update -y
sudo apt install -y jq apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common docker.io redis-server

echo
echo "UPDATING HOSTNAME"
echo "-----------------------------------------------------------------"
hostnamectl set-hostname kube

echo
echo "SYSCTL PARAMETERS"
echo "-----------------------------------------------------------------"
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

echo
echo "DISABLING SWAP"
echo "-----------------------------------------------------------------"
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo
echo "INSTALLING CONTAINERD"
echo "-----------------------------------------------------------------"
wget -q https://github.com/containerd/containerd/releases/download/v1.7.23/containerd-1.7.23-linux-amd64.tar.gz
sudo tar Cxzvf /usr/local containerd-1.7.23-linux-amd64.tar.gz
wget -q https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
sudo mkdir -p /usr/local/lib/systemd/system
sudo mv containerd.service /usr/local/lib/systemd/system/containerd.service
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

echo
echo "INSTALLING RUNC AND CNI PLUGINS"
echo "-----------------------------------------------------------------"
wget -q https://github.com/opencontainers/runc/releases/download/v1.1.15/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc
wget -q https://github.com/containernetworking/plugins/releases/download/v1.6.0/cni-plugins-linux-amd64-v1.6.0.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.6.0.tgz

echo
echo "CONFIGURING CONTAINERD"
echo "-----------------------------------------------------------------"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

echo
echo "CONFIGURING KUBERNETES REPO"
echo "-----------------------------------------------------------------"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update -y

echo
echo "INSTALLING KUBEADM, KUBELET, KUBECTL"
echo "-----------------------------------------------------------------"
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo
echo "INITIALIZING KUBERNETES CLUSTER"
echo "-----------------------------------------------------------------"
LOCAL_IP=$(hostname -I | awk '{print $1}')
sudo kubeadm init --apiserver-advertise-address="$LOCAL_IP" --pod-network-cidr=10.244.0.0/16 --cri-socket unix:///var/run/containerd/containerd.sock

echo
echo "CONFIGURING KUBECTL ACCESS"
echo "-----------------------------------------------------------------"
mkdir -p /home/azureuser/.kube
sudo cp /etc/kubernetes/admin.conf /home/azureuser/.kube/config
sudo chown -R azureuser:azureuser /home/azureuser/

echo
echo "APPLYING NETWORKING ADDON"
echo "-----------------------------------------------------------------"
sudo kubectl --kubeconfig=/home/azureuser/.kube/config apply -f https://reweave.azurewebsites.net/k8s/v1.31/net.yaml

sudo systemctl enable --now docker
sudo usermod -aG docker azureuser

echo
echo "CLEANING UP"
echo "-----------------------------------------------------------------"
rm -f containerd-1.7.23-linux-amd64.tar.gz cni-plugins-linux-amd64-v1.6.0.tgz runc.amd64

kubectl --kubeconfig=/home/azureuser/.kube/config taint nodes --all node-role.kubernetes.io/control-plane- || true

kubectl --kubeconfig=/home/azureuser/.kube/config apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl --kubeconfig=/home/azureuser/.kube/config patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--kubelet-insecure-tls"}]'

kubectl --kubeconfig=/home/azureuser/.kube/config apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl --kubeconfig=/home/azureuser/.kube/config patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# --- Helm install + Splunk Operator setup ---
cd /home/azureuser/
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh

# Use the azureuser kubeconfig for all helm work
export KUBECONFIG=/home/azureuser/.kube/config

# Add Splunk Helm repo
sudo -u azureuser -E bash -lc 'helm repo add splunk https://splunk.github.io/splunk-operator/ && helm repo update'

# Ensure CRDs exist for the operator
kubectl apply -f https://github.com/splunk/splunk-operator/releases/download/3.0.0/splunk-operator-crds.yaml --server-side

# Install/upgrade the chart and pass the Splunk 10.x license acceptance to the operator
if ! sudo -u azureuser -E bash -lc 'helm status splunk-standalone -n splunk-operator >/dev/null 2>&1'; then
  sudo -u azureuser -E bash -lc '
    helm install splunk-standalone splunk/splunk-enterprise \
      -n splunk-operator \
      --create-namespace \
      --set operator.enabled=true \
      --set operator.env.SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
  '
else
  sudo -u azureuser -E bash -lc '
    helm upgrade splunk-standalone splunk/splunk-enterprise \
      -n splunk-operator \
      --set operator.enabled=true \
      --set operator.env.SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
  '
fi

# Belt & suspenders: also set the env directly on the operator deployment
kubectl -n splunk-operator set env deployment/splunk-operator-controller-manager \
  SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com

# Wait until the operator is ready before PVC work
kubectl -n splunk-operator rollout status deploy/splunk-operator-controller-manager

# PVC FIX: stop operator -> clear stuck PVC/PV -> recreate -> start operator
echo
echo "PVC FIX: ensuring clean app-download PVC"
echo "-----------------------------------------------------------------"
NS="splunk-operator"
PVC_FIXED_PATH="/home/azureuser/fixed-pvc.yml"
APP_PVC_NAME="splunk-operator-app-download"

# Write fixed PVC manifest (idempotent)
cat <<'EOF' > "${PVC_FIXED_PATH}"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: splunk-operator-app-download
  namespace: splunk-operator
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: local-path
  volumeMode: Filesystem
EOF

# Helper: wait for PVC bound
wait_for_pvc_bound () {
  local ns="$1" pvc="$2" timeout="${3:-180}"
  echo "Waiting for PVC ${pvc} in ${ns} to be Bound (timeout ${timeout}s)..."
  local end=$(( $(date +%s) + timeout ))
  while true; do
    phase="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Bound" ]]; then
      echo "PVC ${pvc} is Bound."
      return 0
    fi
    if (( $(date +%s) > end )); then
      echo "ERROR: PVC ${pvc} not Bound after ${timeout}s (phase=${phase:-N/A})."
      return 1
    fi
    sleep 3
  done
}

# Scale operator down so it releases the PVC
kubectl -n "$NS" scale deploy/splunk-operator-controller-manager --replicas=0 || true
kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=splunk-operator --timeout=120s || true

# If PVC exists and is stuck, delete it and its PV; remove finalizers if present
if kubectl -n "$NS" get pvc "$APP_PVC_NAME" >/dev/null 2>&1; then
  echo "Deleting existing PVC ${APP_PVC_NAME}..."
  PV_NAME="$(kubectl -n "$NS" get pvc "$APP_PVC_NAME" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  kubectl -n "$NS" delete pvc "$APP_PVC_NAME" --wait=false || true
  kubectl -n "$NS" patch pvc "$APP_PVC_NAME" -p '{"metadata":{"finalizers":null}}' --type=merge || true
  if [[ -n "${PV_NAME:-}" ]]; then
    echo "Deleting bound PV ${PV_NAME}..."
    kubectl delete pv "$PV_NAME" --wait=false || true
    kubectl patch pv "$PV_NAME" -p '{"metadata":{"finalizers":null}}' --type=merge || true
  fi
fi

# Recreate fixed PVC
kubectl apply -f "${PVC_FIXED_PATH}"

# Bring operator back and wait for it to be ready
kubectl -n "$NS" scale deploy/splunk-operator-controller-manager --replicas=1
kubectl -n "$NS" rollout status deploy/splunk-operator-controller-manager

# Ensure PVC becomes Bound before continuing
wait_for_pvc_bound "$NS" "$APP_PVC_NAME" 240

# Deploy IDX, SH, and NodePort service
cat <<'EOF' > /home/azureuser/idx.yml
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: idx1
  namespace: splunk-operator
spec:
  etcVolumeStorageConfig:
    storageClassName: local-path
    storageCapacity: 10Gi
  varVolumeStorageConfig:
    storageClassName: local-path
    storageCapacity: 10Gi
  resources:
    requests:
      cpu: "1.0"
      memory: "4Gi"
    limits:
      cpu: "2"
      memory: "8Gi"
EOF

cat <<'EOF' > /home/azureuser/idx-node-ports.yml
apiVersion: v1
kind: Service
metadata:
  name: splunk-idx1-standalone-nodeports
  namespace: splunk-operator
spec:
  type: NodePort
  selector:
    app.kubernetes.io/instance: splunk-idx1-standalone
  ports:
    - name: splunktcp
      port: 9997
      targetPort: 9997
    - name: hec
      port: 8088
      targetPort: 8088
    - name: mgmt
      port: 8089
      targetPort: 8089
EOF

cat <<'EOF' > /home/azureuser/sh.yml
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: sh1
  namespace: splunk-operator
spec:
  etcVolumeStorageConfig:
    storageClassName: local-path
    storageCapacity: 10Gi
  varVolumeStorageConfig:
    storageClassName: local-path
    storageCapacity: 10Gi
  serviceTemplate:
    spec:
      type: NodePort
  resources:
    requests:
      cpu: "1.0"
      memory: "4Gi"
    limits:
      cpu: "2"
      memory: "8Gi"
EOF

kubectl apply -f /home/azureuser/idx.yml
kubectl apply -f /home/azureuser/idx-node-ports.yml
kubectl apply -f /home/azureuser/sh.yml

# TRUSTED.PEM COPY + DISTSEARCH
NS="splunk-operator"
SRC="/opt/splunk/etc/auth/distServerKeys/trusted.pem"
DEST_BASE="/opt/splunk/etc/auth/distServerKeys"

wait_for_pods() {
  local ns="$1" label="$2" timeout="${3:-1200}"
  echo "Waiting for pods with label '$label' in ns '$ns' to appear..."
  local start=$(date +%s)
  while true; do
    if kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | grep -q .; then
      break
    fi
    (( $(date +%s) - start > timeout )) && { echo "ERROR: Timed out waiting for pods ($label)"; exit 1; }
    sleep 3
  done
  echo "Waiting for pods with label '$label' to be Ready (timeout ${timeout}s)..."
  local remaining=$timeout
  while (( remaining > 0 )); do
    if kubectl get pods -n "$ns" -l "$label" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -q True; then
      echo "Pods with label '$label' are Ready."
      return 0
    fi
    printf "\rWaiting... %02d:%02d remaining" $((remaining/60)) $((remaining%60))
    sleep 5
    ((remaining-=5))
  done
  echo -e "\nERROR: Pods not Ready after ${timeout} seconds."
  exit 1
}

SH_LABEL="app.kubernetes.io/instance=splunk-sh1-standalone"
IDX_LABEL="app.kubernetes.io/instance=splunk-idx1-standalone"

wait_for_pods "$NS" "$SH_LABEL"
wait_for_pods "$NS" "$IDX_LABEL"

SH_POD=$(kubectl get pod -n "$NS" -l "$SH_LABEL" -o jsonpath='{.items[0].metadata.name}')
read -r -a IDX_PODS <<<"$(kubectl get pod -n "$NS" -l "$IDX_LABEL" -o jsonpath='{range .items[*]}{.metadata.name} {end}')"

# Get admin password from secret
SPLUNK_ADMIN_PASSWORD="$(kubectl -n "$NS" get secret splunk-sh1-standalone-secret-v1 -o jsonpath='{.data.password}' | base64 --decode)"

# Determine Splunk "serverName" (preferred) with fallbacks
SH_SERVERNAME="$(
  kubectl exec -n "$NS" "$SH_POD" -- bash -lc "
    set -e
    if /opt/splunk/bin/splunk show servername -auth admin:'$SPLUNK_ADMIN_PASSWORD' >/tmp/sn 2>/dev/null; then
      awk '{print \$NF}' /tmp/sn
    elif grep -E '^serverName=' /opt/splunk/etc/system/local/server.conf >/dev/null 2>&1; then
      awk -F= '/^serverName=/{print \$2}' /opt/splunk/etc/system/local/server.conf
    elif [ -f /etc/hostname ]; then
      cat /etc/hostname
    else
      printenv HOSTNAME || true
    fi
  " | tr -d '\r' | head -n1
)"
if [[ -z "$SH_SERVERNAME" ]]; then
  echo "ERROR: Could not determine Search Head serverName"; exit 1
fi
echo "Search Head serverName: ${SH_SERVERNAME}"

# Copy trusted.pem from SH to each IDX under distServerKeys/<serverName>/
for IDX in "${IDX_PODS[@]}"; do
  kubectl exec -n "$NS" "$IDX" -- bash -lc "mkdir -p '$DEST_BASE/$SH_SERVERNAME'"
  kubectl exec -n "$NS" "$SH_POD" -- cat "$SRC" \
  | kubectl exec -i -n "$NS" "$IDX" -- bash -lc "
      cat > '$DEST_BASE/$SH_SERVERNAME/trusted.pem'
      chown splunk:splunk '$DEST_BASE/$SH_SERVERNAME/trusted.pem'
      chmod 0644 '$DEST_BASE/$SH_SERVERNAME/trusted.pem'
    "
done

# Discover public IP
PUBLIC_IP="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(curl -s http://checkip.amazonaws.com || true)"
fi

# Get NodePort for mgmt
IDX_NODEPORT_SVC="splunk-idx1-standalone-nodeports"
MGMT_PORT=$(kubectl -n "$NS" get svc "$IDX_NODEPORT_SVC" -o jsonpath='{.spec.ports[?(@.name=="mgmt")].nodePort}')

# Write distsearch.conf on the SH
kubectl exec -i -n "$NS" "$SH_POD" -- bash -lc "
  mkdir -p /opt/splunk/etc/system/local
  cat > /opt/splunk/etc/system/local/distsearch.conf <<'CONF'
[distributedSearch]
servers = https://${PUBLIC_IP}:${MGMT_PORT}
CONF
  chown splunk:splunk /opt/splunk/etc/system/local/distsearch.conf
  chmod 0644 /opt/splunk/etc/system/local/distsearch.conf
"

# Restart Splunk
kubectl exec -n "$NS" "$SH_POD" -- /opt/splunk/bin/splunk restart --accept-license --answer-yes
for IDX in "${IDX_PODS[@]}"; do
  kubectl exec -n "$NS" "$IDX" -- /opt/splunk/bin/splunk restart --accept-license --answer-yes
done

# CONFIGURING CRIBL LEADER HELM CHARTS

# Add cribl helm repo
sudo -u azureuser -E bash -lc 'KUBECONFIG=/home/azureuser/.kube/config helm repo add cribl https://criblio.github.io/helm-charts/'
sudo -u azureuser -E bash -lc 'KUBECONFIG=/home/azureuser/.kube/config helm repo update'

# Create cribl-leader.yml 
cat <<'EOF' > cribl-leader.yml
persistence:
  enabled: true
  size: 5Gi
extraInitContainers:
  - name: seed-config
    image: cribl/cribl:4.13.0
    command: ["sh","-c"]
    args:
      - |
        set -e
        mkdir -p /mnt/local /mnt/default
        if [ -z "$(ls -A /mnt 2>/dev/null)" ]; then
          cp -a /opt/cribl/local /mnt/ || true
          cp -a /opt/cribl/default /mnt/ || true
        fi
        chown -R 1000:1000 /mnt || true
    volumeMounts:
      - name: config-storage
        mountPath: /mnt
config:
  token: "changeme"
  adminPassword: "changeme"
  groups: ["wg1"]
  acceptLicense: true
autoscaling:
  enabled: false
replicaCount: 1
service:
  externalType: NodePort
resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "1"
    memory: "2Gi"
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
EOF

# Create minimal, distributed leader (1 group)
sudo -u azureuser -E bash -lc 'KUBECONFIG=/home/azureuser/.kube/config helm install ls-leader cribl/logstream-leader --create-namespace -n cribl-stream -f /home/azureuser/cribl-leader.yml'

# Create cribl worker-group (wg1) values
cat <<'EOF' > cribl-wg1.yml
config:
  host: "ls-leader-internal"
  tag: "wg1"
  token: "changeme"
autoscaling:
  enabled: false
replicaCount: 1
resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "1"
    memory: "2Gi"
EOF

# Install the single worker group
sudo -u azureuser -E bash -lc 'KUBECONFIG=/home/azureuser/.kube/config helm install ls-wg1 cribl/logstream-workergroup -n cribl-stream -f /home/azureuser/cribl-wg1.yml'

# CRIBL CONFIG (pipelines first)
CRIBL_NS="cribl-stream"
SPLUNK_NS="splunk-operator"

wait_for_ready() {
  local ns="$1" sel="$2" timeout="${3:-300}"
  echo "Waiting for pods ($sel) in ns=$ns to be Ready (timeout ${timeout}s)..."
  local start=$(date +%s)
  while true; do
    local cnt
    cnt=$(kubectl -n "$ns" get pods -l "$sel" --no-headers 2>/dev/null | wc -l | xargs)
    [[ "$cnt" != "0" ]] && break
    (( $(date +%s) - start > timeout )) && { echo "Timed out waiting for pods to appear: $sel"; exit 1; }
    sleep 3
  done
  while true; do
    local statuses
    statuses=$(kubectl -n "$ns" get pods -l "$sel" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{" "}{end}')
    if echo "$statuses" | grep -q '\bTrue\b'; then
      echo "Ready."
      return 0
    fi
    (( $(date +%s) - start > timeout )) && { echo "Timed out waiting for Ready: $sel"; exit 1; }
    sleep 5
  done
}

LEADER_SEL='app.kubernetes.io/instance=ls-leader,app.kubernetes.io/name=leader'
WORKER_SEL='app.kubernetes.io/instance=ls-wg1,app.kubernetes.io/name=logstream-workergroup'

wait_for_ready "$CRIBL_NS" "$LEADER_SEL" 300
wait_for_ready "$CRIBL_NS" "$WORKER_SEL" 300

LEADER_POD="$(kubectl -n "$CRIBL_NS" get pod -l app.kubernetes.io/instance=ls-leader,app.kubernetes.io/name=leader -o jsonpath='{.items[0].metadata.name}')"

# Paths
WG_TAG="wg1"
REMOTE_BASE="/opt/cribl/config-volume/groups/${WG_TAG}/local/cribl"
REMOTE_PIPELINES="${REMOTE_BASE}/pipelines"
kubectl -n "$CRIBL_NS" exec "$LEADER_POD" -- bash -lc "mkdir -p '${REMOTE_PIPELINES}'"

# ------- Create BOTH pipeline dirs & confs *before* routes/outputs -------
# HGET pipeline
PIPE_HGET="redis-hget"
PIPE_HGET_DIR="${REMOTE_PIPELINES}/${PIPE_HGET}"
kubectl -n "$CRIBL_NS" exec "$LEADER_POD" -- bash -lc "mkdir -p '${PIPE_HGET_DIR}'"

# HSET pipeline
PIPE_HSET="redis-hset"
PIPE_HSET_DIR="${REMOTE_PIPELINES}/${PIPE_HSET}"
kubectl -n "$CRIBL_NS" exec "$LEADER_POD" -- bash -lc "mkdir -p '${PIPE_HSET_DIR}'"

# Build local temp files
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# HGET conf
cat > "${TMPDIR}/cribl-hget-conf.yml" <<'EOF_CONF_HGET'
output: default
streamtags: []
groups: {}
asyncFuncTimeout: 1000
functions:
  - id: regex_extract
    filter: "!env_id"
    disabled: false
    conf:
      source: _raw
      iterations: 100
      overwrite: false
      regex: /(?<cribl_src_ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/
      regexList:
        - regex: /(?<cribl_name>\w+\.\w+\.\w+\.com)/
    description: extracting fields to test redis hget function
  - id: redis
    filter: "!env_id"
    disabled: false
    conf:
      commands:
        - outField: env_id
          command: hget
          keyExpr: "'dest'"
          argsExpr: "[ String(cribl_src_ip || cribl_name ).trim() ]"
      deploymentType: standalone
      authType: textSecret
      maxBlockSecs: 60
      tlsOptions:
        rejectUnauthorized: true
      url: "'redis://10.0.1.4:6379'"
      textSecret: redis_secret
    description: tagging events
  - id: redis
    filter: "!env_id"
    disabled: false
    conf:
      commands:
        - outField: env_id
          command: hget
          keyExpr: "'src'"
          argsExpr: "[ String(cribl_src_ip).trim() ]"
      deploymentType: standalone
      authType: textSecret
      maxBlockSecs: 60
      tlsOptions:
        rejectUnauthorized: true
      url: "'redis://10.0.1.4:6379'"
      textSecret: redis_secret
    description: tagging events
  - id: redis
    filter: "!env_id"
    disabled: false
    conf:
      commands:
        - outField: env_id
          command: hget
          keyExpr: "'asset'"
          argsExpr: "[ String(cribl_src_ip || cribl_name).trim() ]"
      deploymentType: standalone
      authType: textSecret
      maxBlockSecs: 60
      tlsOptions:
        rejectUnauthorized: true
      url: "'redis://10.0.1.4:6379'"
      textSecret: redis_secret
    description: tagging events
  - id: eval
    filter: env_id
    disabled: false
    conf:
      add:
        - disabled: false
          name: env_id
          value: JSON.parse(env_id).env_id
        - disabled: true
          name: env_id
          value: 'Array.isArray(JSON.parse(env_id).env_id) ?
            JSON.parse(env_id).env_id.join(",") : JSON.parse(env_id).env_id'
        - disabled: true
          name: env_id
          value: 'Array.isArray(env_id) ? env_id.join("\n") : env_id'
    description: parsing env_id field
EOF_CONF_HGET

# HSET conf
cat > "${TMPDIR}/cribl-hset-conf.yml" <<'EOF_CONF_HSET'
output: default
streamtags: []
groups: {}
asyncFuncTimeout: 1000
functions:
  - id: serde
    filter: "true"
    disabled: false
    conf:
      mode: extract
      type: json
      srcField: _raw
    description: extracting result field
  - id: redis
    filter: "true"
    disabled: false
    conf:
      commands:
        - command: hset
          keyExpr: "'dest'"
          argsExpr: "[result.cribl_ip, JSON.stringify({ env_id: result.env_id })]"
        - command: hset
          keyExpr: "'dest'"
          argsExpr: "[result.cribl_name, JSON.stringify({ env_id: result.env_id })]"
        - command: hset
          keyExpr: "'src'"
          argsExpr: "[result.cribl_ip, JSON.stringify({ env_id: result.env_id })]"
        - command: hset
          keyExpr: "'asset'"
          argsExpr: "[result.cribl_ip, JSON.stringify({ env_id: result.env_id })]"
        - argsExpr: "[result.cribl_name, JSON.stringify({ env_id: result.env_id })]"
          keyExpr: "'asset'"
          command: hset
      deploymentType: standalone
      authType: textSecret
      maxBlockSecs: 60
      tlsOptions:
        rejectUnauthorized: true
      rootNodes:
        - {}
      scaleReads: master
      url: "'redis://10.0.1.4:6379'"
      textSecret: redis_secret
    description: storing hashes in redis
    final: false
EOF_CONF_HSET

# Copy pipeline confs and set perms
kubectl -n "$CRIBL_NS" cp "${TMPDIR}/cribl-hget-conf.yml" "${LEADER_POD}:${PIPE_HGET_DIR}/conf.yml"
kubectl -n "$CRIBL_NS" cp "${TMPDIR}/cribl-hset-conf.yml" "${LEADER_POD}:${PIPE_HSET_DIR}/conf.yml"
kubectl -n "$CRIBL_NS" exec "$LEADER_POD" -- bash -lc "chown -R 1000:1000 '${REMOTE_PIPELINES}' && chmod 0644 '${PIPE_HGET_DIR}/conf.yml' '${PIPE_HSET_DIR}/conf.yml'"

# ---------------- After pipelines exist, write routes/jobs/secrets/outputs ----------------
# routes
cat > "${TMPDIR}/route.yml" <<'EOF_ROUTE'
id: default
groups: {}
comments: []
routes:
  - id: zMY8LG
    name: set-env-id
    final: true
    disabled: false
    pipeline: redis-hset
    description: ""
    enableOutputExpression: false
    outputExpression: null
    filter: __collectible.collectorId.startsWith("splunk-make-results-set")
    clones: []
    output: devnull
  - id: 58pTTP
    name: get-env-id
    final: true
    disabled: false
    pipeline: passthru
    description: ""
    enableOutputExpression: false
    outputExpression: null
    filter: __collectible.collectorId=="splunk-make-results-get-env-id"
    clones: []
    output: splunk-idx
  - id: default
    name: default
    final: true
    disabled: false
    pipeline: main
    description: ""
    enableOutputExpression: false
    outputExpression: null
    filter: "true"
    clones: []
    output: default
EOF_ROUTE

# Discover SH mgmt NodePort for jobs
echo "Discovering SH mgmt NodePort (8089) in namespace ${NS} (splunk)…"
SH_SVC="${SH_SVC:-splunk-sh1-standalone-service}"
if kubectl -n "$NS" get svc "$SH_SVC" >/dev/null 2>&1; then
  SH_MGMT_NODEPORT="$(
    kubectl -n "$NS" get svc "$SH_SVC" -o json \
    | jq -r '.spec.ports | map(select(.port==8089 or .targetPort==8089 or (.name//"")=="mgmt") | .nodePort) | map(select(.!=null)) | .[0]'
  )"
else
  SH_MGMT_NODEPORT="$(
    kubectl -n "$NS" get svc -l app.kubernetes.io/instance=splunk-sh1-standalone -o json \
    | jq -r '[.items[] | select(.spec.type=="NodePort") | .spec.ports[] | select(.port==8089 or .targetPort==8089 or (.name//"")=="mgmt") | .nodePort] | map(select(.!=null)) | .[0]'
  )"
fi
if [[ -z "${SH_MGMT_NODEPORT}" || "${SH_MGMT_NODEPORT}" == "null" ]]; then
  echo "ERROR: Could not determine NodePort for 8089 on the Search Head service in namespace ${NS}."
  echo "Hint: set SH_SVC to your SH service name, e.g.: export SH_SVC='splunk-sh1-standalone-service'"
  exit 1
fi

# Splunk admin password for jobs
SPLUNK_ADMIN_PASSWORD="$(kubectl -n "$NS" get secret splunk-sh1-standalone-secret-v1 -o jsonpath='{.data.password}' | base64 --decode)"
if [[ -z "${SPLUNK_ADMIN_PASSWORD}" ]]; then
  echo "ERROR: Could not retrieve Splunk admin password from secret splunk-sh1-standalone-secret-v1 in ${NS}."
  exit 1
fi

# Public IP for jobs and outputs
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
  [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(curl -s http://checkip.amazonaws.com || true)"
fi

# jobs.yml
cat > "${TMPDIR}/jobs.yml" <<EOF_JOBS
splunk-make-results-get-env-id:
  type: collection
  ttl: 4h
  ignoreGroupJobsLimit: false
  removeFields: []
  resumeOnBoot: false
  schedule:
    cronSchedule: "* * * * *"
    maxConcurrentRuns: 1
    skippable: false
    resumeMissed: false
    run:
      rescheduleDroppedTasks: true
      maxTaskReschedule: 1
      logLevel: info
      jobTimeout: "0"
      mode: run
      timeRangeType: relative
      timeWarning: {}
      expression: "true"
      minTaskSize: 1MB
      maxTaskSize: 10MB
    enabled: false
  streamtags: []
  workerAffinity: false
  collector:
    conf:
      searchHead: "https://${PUBLIC_IP}:${SH_MGMT_NODEPORT}"
      endpoint: /services/search/v2/jobs/export
      outputMode: json
      authentication: basic
      timeout: 0
      useRoundRobinDns: false
      disableTimeFilter: true
      rejectUnauthorized: false
      retryRules:
        type: backoff
        interval: 1000
        limit: 5
        multiplier: 2
        codes:
          - 429
          - 503
        enableHeader: true
        retryConnectTimeout: false
        retryConnectReset: false
      username: "admin"
      password: "${SPLUNK_ADMIN_PASSWORD}"
      search: '| makeresults  | eval _raw=strftime(now(),"%b %d %H:%M:%S")." web01
        sshd[2143]: Failed password for invalid user bob from db9.corp.example.com port
        55101 ssh2" | append [| makeresults | eval _raw=strftime(now(),"%b %d
        %H:%M:%S")." db01 sshd[1189]: Accepted password for alice from
        192.168.1.2 port 55102 ssh2"] | append [| makeresults | eval
        _raw=strftime(now(),"%b %d %H:%M:%S")." app01 sshd[3321]: Failed
        password for root from 192.168.1.3 port 55103 ssh2"] | append [|
        makeresults | eval _raw=strftime(now(),"%b %d %H:%M:%S")." bastion01
        sshd[4452]: Accepted publickey for deploy from 192.168.1.4 port 55104
        ssh2"] | append [| makeresults | eval _raw=strftime(now(),"%b %d
        %H:%M:%S")." ldap01 sshd[772]: Failed password for invalid user test
        from 192.168.1.5 port 55105 ssh2"] | append [| makeresults | eval
        _raw=strftime(now(),"%b %d %H:%M:%S")." git01 sshd[909]: Accepted
        password for git from 192.168.1.6 port 55106 ssh2"] | append [|
        makeresults | eval _raw=strftime(now(),"%b %d %H:%M:%S")." jump01
        sshd[1201]: Failed password for admin from 192.168.1.7 port 55107 ssh2"]
        | append [| makeresults | eval _raw=strftime(now(),"%b %d %H:%M:%S")."
        cache01 sshd[1902]: Accepted publickey for svc_cache from 192.168.1.8
        port 55108 ssh2"] | append [| makeresults | eval _raw=strftime(now(),"%b
        %d %H:%M:%S")." vpn01 sshd[2003]: Failed password for unknown from
        192.168.1.9 port 55109 ssh2"] | append [| makeresults | eval
        _raw=strftime(now(),"%b %d %H:%M:%S")." mail01 sshd[2311]: Accepted
        password for postfix from 192.168.1.10 port 55110 ssh2"]  | rex
        field=_raw ": (?<message>[^$]+)" | rex field=_raw
        "^\w+\s+\d+\s+\d+:\d+:\d+\s+(?<host>\S+)\s" | rex field=_raw
        "from\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})" | eval
        fqdn=host.".corp.example.com"  | table host ip fqdn message'
    destructive: false
    encoding: utf8
    type: splunk
  input:
    type: collection
    staleChannelFlushMs: 10000
    sendToRoutes: true
    preprocess:
      disabled: true
    throttleRatePerSec: "0"
  savedState: {}
  notifications: []
  description: Using Splunk's make result command to create events to test the
    redis hget function with.
splunk-make-results-set-src-env-id:
  type: collection
  ttl: 4h
  ignoreGroupJobsLimit: false
  removeFields: []
  resumeOnBoot: false
  schedule:
    cronSchedule: "* * * * *"
    maxConcurrentRuns: 1
    skippable: false
    resumeMissed: false
    run:
      rescheduleDroppedTasks: true
      maxTaskReschedule: 1
      logLevel: info
      jobTimeout: "0"
      mode: run
      timeRangeType: relative
      timeWarning: {}
      expression: "true"
      minTaskSize: 1MB
      maxTaskSize: 10MB
    enabled: false
  streamtags: []
  workerAffinity: false
  collector:
    conf:
      searchHead: "https://${PUBLIC_IP}:${SH_MGMT_NODEPORT}"
      endpoint: /services/search/v2/jobs/export
      outputMode: json
      authentication: basic
      timeout: 0
      useRoundRobinDns: false
      disableTimeFilter: true
      rejectUnauthorized: false
      retryRules:
        type: backoff
        interval: 1000
        limit: 5
        multiplier: 2
        codes:
          - 429
          - 503
        enableHeader: true
        retryConnectTimeout: false
        retryConnectReset: false
      username: "admin"
      password: "${SPLUNK_ADMIN_PASSWORD}"
      search: '| makeresults  | eval n=mvrange(1,21)  | mvexpand n  | eval src_ip="10.0.0.".n, src_environment_id=1000+n  | eval src_environment_id=case(     n=3, mvappend("1003","1103"),     n=7, mvappend("1007","1107"),     true(), tostring(src_environment_id)   )  | mvexpand src_environment_id  | stats values(src_environment_id) AS src_environment_id BY src_ip | eval src_environment_id=mvsort(src_environment_id) | eval last=tonumber(mvindex(split(src_ip,"."),-1)) | eval locs="us-east-1a,us-east-1b,us-west-2a,us-west-2b,corp-core,corp-dmz,eu-central-1a,eu-west-1b,ap-southeast-1a,ap-southeast-2b" | eval loc=split(locs,",") | eval cribl_netloc=mvindex(loc, last % mvcount(loc)) | fields - locs loc last | rename src_ip as cribl_ip src_environment_id as env_id  | table cribl_ip env_id cribl_netloc'
    destructive: false
    encoding: utf8
    type: splunk
  input:
    type: collection
    staleChannelFlushMs: 10000
    sendToRoutes: true
    preprocess:
      disabled: true
    throttleRatePerSec: "0"
  savedState: {}
  notifications: []
  description: Using Splunk's make result command to create events to test the
    redis hset function with.
splunk-make-results-set-asset-env-id:
  type: collection
  ttl: 4h
  ignoreGroupJobsLimit: false
  removeFields: []
  resumeOnBoot: false
  schedule:
    cronSchedule: "* * * * *"
    maxConcurrentRuns: 1
    skippable: false
    resumeMissed: false
    run:
      rescheduleDroppedTasks: true
      maxTaskReschedule: 1
      logLevel: info
      jobTimeout: "0"
      mode: run
      timeRangeType: relative
      timeWarning: {}
      expression: "true"
      minTaskSize: 1MB
      maxTaskSize: 10MB
    enabled: false
  streamtags: []
  workerAffinity: false
  collector:
    conf:
      searchHead: "https://${PUBLIC_IP}:${SH_MGMT_NODEPORT}"
      endpoint: /services/search/v2/jobs/export
      outputMode: json
      authentication: basic
      timeout: 0
      useRoundRobinDns: false
      disableTimeFilter: true
      rejectUnauthorized: false
      retryRules:
        type: backoff
        interval: 1000
        limit: 5
        multiplier: 2
        codes:
          - 429
          - 503
        enableHeader: true
        retryConnectTimeout: false
        retryConnectReset: false
      username: "admin"
      password: "${SPLUNK_ADMIN_PASSWORD}"
      search: '| makeresults  | eval n=mvrange(1,21)  | mvexpand n  | eval asset_ip="172.16.0.".n, asset_environment_id=5000+n  | eval asset_environment_id=case(     n=2, mvappend("5002","5102"),     n=15, mvappend("5015","5115"),     true(), tostring(asset_environment_id)   )  | mvexpand asset_environment_id  | stats values(asset_environment_id) AS asset_environment_id BY asset_ip  | eval asset_environment_id=mvsort(asset_environment_id)  | eval octet=tonumber(mvindex(split(asset_ip,"."),-1)) | eval cribl_name="host".octet.".corp.example.com" | eval locs="us-east-1a,us-east-1b,us-west-2a,us-west-2b,corp-core,corp-dmz,eu-central-1a,eu-west-1b,ap-southeast-1a,ap-southeast-2b" | eval loc=split(locs,",") | eval cribl_netloc=mvindex(loc, octet % mvcount(loc)) | fields - locs loc octet | rename asset_ip as cribl_ip asset_environment_id as env_id  | table cribl_ip env_id cribl_name cribl_netloc'
    destructive: false
    encoding: utf8
    type: splunk
  input:
    type: collection
    staleChannelFlushMs: 10000
    sendToRoutes: true
    preprocess:
      disabled: true
    throttleRatePerSec: "0"
  savedState: {}
  notifications: []
  description: Using Splunk's make result command to create events to test the
    redis hset function with.
splunk-make-results-set-dest-env-id:
  type: collection
  ttl: 4h
  ignoreGroupJobsLimit: false
  removeFields: []
  resumeOnBoot: false
  schedule:
    cronSchedule: "* * * * *"
    maxConcurrentRuns: 1
    skippable: false
    resumeMissed: false
    run:
      rescheduleDroppedTasks: true
      maxTaskReschedule: 1
      logLevel: info
      jobTimeout: "0"
      mode: run
      timeRangeType: relative
      timeWarning: {}
      expression: "true"
      minTaskSize: 1MB
      maxTaskSize: 10MB
    enabled: false
  streamtags: []
  workerAffinity: false
  collector:
    conf:
      searchHead: "https://${PUBLIC_IP}:${SH_MGMT_NODEPORT}"
      endpoint: /services/search/v2/jobs/export
      outputMode: json
      authentication: basic
      timeout: 0
      useRoundRobinDns: false
      disableTimeFilter: true
      rejectUnauthorized: false
      retryRules:
        type: backoff
        interval: 1000
        limit: 5
        multiplier: 2
        codes:
          - 429
          - 503
        enableHeader: true
        retryConnectTimeout: false
        retryConnectReset: false
      username: "admin"
      password: "${SPLUNK_ADMIN_PASSWORD}"
      search: '| makeresults  | eval n=mvrange(1,21)  | mvexpand n  | eval role=mvindex(split("web,app,db",","), (n-1)%3)  | eval dest_ip="192.168.1.".n, dest_environment_id=2000+n, dest_hostname=role.n.".corp.example.com"  | eval dest_environment_id=case(      n=5, mvappend("2005","2105"),      n=10, mvappend("2010","2110"),      true(), tostring(dest_environment_id)    )  | mvexpand dest_environment_id  | stats values(dest_environment_id) AS dest_environment_id latest(dest_hostname) AS dest_hostname BY dest_ip  | eval dest_environment_id=mvsort(dest_environment_id)  | eval last=tonumber(mvindex(split(dest_ip,"."),-1))  | eval locs="us-east-1a,us-east-1b,us-west-2a,us-west-2b,corp-core,corp-dmz,eu-central-1a,eu-west-1b,ap-southeast-1a,ap-southeast-2b"  | eval loc=split(locs,",")  | eval cribl_netloc=mvindex(loc, last % mvcount(loc))  | fields - locs loc last  | rename dest_ip as cribl_ip dest_environment_id as env_id dest_hostname as cribl_name  | table cribl_ip env_id cribl_name cribl_netloc'
    destructive: false
    encoding: utf8
    type: splunk
  input:
    type: collection
    staleChannelFlushMs: 10000
    sendToRoutes: true
    preprocess:
      disabled: true
    throttleRatePerSec: "0"
  savedState: {}
  notifications: []
  description: Using Splunk's make result command to create events to test the
    redis hset function with.
EOF_JOBS

# secrets.yml
cat > "${TMPDIR}/secrets.yml" <<'EOF_SECRETS'
redis_secret:
  secretType: text
  secrets:
    value: "changeme"
EOF_SECRETS

# Find Splunk TCP NodePort (9997)
SPLUNK_IDX_NODEPORT_SVC="splunk-idx1-standalone-nodeports"
SPLUNK_TCP_NODEPORT="$(kubectl -n "$SPLUNK_NS" get svc "$SPLUNK_IDX_NODEPORT_SVC" -o jsonpath='{.spec.ports[?(@.name=="splunktcp")].nodePort}')"
if [[ -z "$SPLUNK_TCP_NODEPORT" ]]; then
  SPLUNK_TCP_NODEPORT="$(kubectl -n "$SPLUNK_NS" get svc "$SPLUNK_IDX_NODEPORT_SVC" -o jsonpath='{.spec.ports[?(@.port==9997)].nodePort}')"
fi

# outputs.yml (points to HGET pipeline)
cat > "${TMPDIR}/outputs.yml" <<EOF_OUT
outputs:
  splunk-idx:
    systemFields:
      - cribl_pipe
    streamtags: []
    port: ${SPLUNK_TCP_NODEPORT}
    nestedFields: none
    throttleRatePerSec: "0"
    connectionTimeout: 10000
    writeTimeout: 60000
    tls:
      disabled: true
    enableMultiMetrics: false
    enableACK: true
    logFailedRequests: false
    maxS2Sversion: v4
    onBackpressure: block
    authType: manual
    compress: disabled
    authToken: ""
    type: splunk
    host: ${PUBLIC_IP}
    pipeline: ${PIPE_HGET}
EOF_OUT

# Copy routes/jobs/secrets/outputs and set perms
kubectl -n "$CRIBL_NS" cp "${TMPDIR}/route.yml"   "${LEADER_POD}:${REMOTE_BASE}/pipelines/route.yml"
kubectl -n "$CRIBL_NS" cp "${TMPDIR}/jobs.yml"    "${LEADER_POD}:${REMOTE_BASE}/jobs.yml"
kubectl -n "$CRIBL_NS" cp "${TMPDIR}/secrets.yml" "${LEADER_POD}:${REMOTE_BASE}/secrets.yml"
kubectl -n "$CRIBL_NS" cp "${TMPDIR}/outputs.yml" "${LEADER_POD}:${REMOTE_BASE}/outputs.yml"
kubectl -n "$CRIBL_NS" exec "$LEADER_POD" -- bash -lc "chown -R 1000:1000 '${REMOTE_BASE}' && chmod 0644 '${REMOTE_BASE}/jobs.yml' '${REMOTE_BASE}/secrets.yml' '${REMOTE_BASE}/outputs.yml'"

echo "Created ${REMOTE_BASE}/outputs.yml with host=${PUBLIC_IP}, port=${SPLUNK_TCP_NODEPORT}"

# Optional: push config immediately (doesn't fail script if not available)
kubectl -n "$CRIBL_NS" exec "$LEADER_POD" -- cribl admin deploy --groups "${WG_TAG}" || true

# restart cribl 
LEADER_POD="$(kubectl get pods -n "$CRIBL_NS" -l app.kubernetes.io/name=leader,app.kubernetes.io/instance=ls-leader -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' | head -n1)"
if [[ -z "${LEADER_POD:-}" ]]; then
  echo "No running leader pod found in namespace $CRIBL_NS" >&2
  exit 1
fi
echo "Restarting Cribl inside pod: $LEADER_POD"
kubectl exec -n "$CRIBL_NS" "$LEADER_POD" -- /opt/cribl/bin/cribl restart

# getting secret (kept for your diagnostics)
kubectl get secret splunk-sh1-standalone-secret-v1 -n splunk-operator -o jsonpath="{.data.password}" | base64 --decode > password.txt && echo >> password.txt

# getting services (kept for your diagnostics)
kubectl get svc -A > services.txt

# INSTALL REDIS

REDIS_CONF="/etc/redis/redis.conf"
BIND_IP="10.0.1.4"
REDIS_PASS="changeme"

# Backup the original file
cp "$REDIS_CONF" "${REDIS_CONF}.bak_$(date +%F_%T)"

# Comment out existing bind line
sed -i 's/^\s*bind 127\.0\.0\.1 ::1/# &/' "$REDIS_CONF"

# Add new bind line after the commented one
sed -i "/^#\s*bind 127\.0\.0\.1 ::1/a bind ${BIND_IP}" "$REDIS_CONF"

# Add/Update requirepass
if grep -q "^requirepass" "$REDIS_CONF"; then
    sed -i "s/^requirepass.*/requirepass ${REDIS_PASS}/" "$REDIS_CONF"
else
    echo "requirepass ${REDIS_PASS}" >> "$REDIS_CONF"
fi

sudo systemctl restart redis 

# Log time ended
echo "Script finished: $(date)" >> /home/azureuser/timer.txt

# Set up post_deploy_info.sh
cat <<'EOF' > /home/azureuser/post_deploy_info.sh
#!/usr/bin/env bash
set -euo pipefail

# --- Config (adjust if you used different release/namespace names) ---
CRIBL_NS="${CRIBL_NS:-cribl-stream}"
CRIBL_LABEL_INSTANCE="${CRIBL_LABEL_INSTANCE:-ls-leader}"

SPLUNK_NS="${SPLUNK_NS:-splunk-operator}"
SPLUNK_SH_INSTANCE="${SPLUNK_SH_INSTANCE:-splunk-sh1-standalone}"
SPLUNK_IDX_INSTANCE="${SPLUNK_IDX_INSTANCE:-splunk-idx1-standalone}"

PASS_FILE="${PASS_FILE:-password.txt}"
REDIS_PASS="${REDIS_PASS:-changeme}"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have kubectl; then
  echo "ERROR: kubectl not found in PATH." >&2
  exit 1
fi
if ! have jq; then
  echo "ERROR: jq not found in PATH (apt install -y jq)." >&2
  exit 1
fi

# Public IP of first node (adjust if you run multiple/external balancer)
PUBLIC_IP="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  # Fallback: try to detect via external service (may not work in all envs)
  PUBLIC_IP="$(curl -fsS http://checkip.amazonaws.com || true)"
fi

# --- Find Cribl Leader NodePort for 9000 ---
CRIBL_NODEPORT="$(
  kubectl -n "$CRIBL_NS" get svc -l "app.kubernetes.io/instance=${CRIBL_LABEL_INSTANCE},app.kubernetes.io/name=leader" -o json \
  | jq -r '
      .items[]
      | select(.spec.type=="NodePort")
      | .spec.ports[]
      | select((.port==9000) or (.targetPort==9000) or ((.name//"")|test("web|ui|http|9000";"i")))
      | .nodePort
    ' | head -n1
)"
[[ -z "${CRIBL_NODEPORT}" || "${CRIBL_NODEPORT}" == "null" ]] && CRIBL_NODEPORT="(not found)"

# --- Find Splunk SH NodePort for 8000 ---
SPLUNK_SH_NODEPORT="$(
  kubectl -n "$SPLUNK_NS" get svc -l "app.kubernetes.io/instance=${SPLUNK_SH_INSTANCE}" -o json \
  | jq -r '
      .items[]
      | select(.spec.type=="NodePort")
      | .spec.ports[]
      | select((.port==8000) or (.targetPort==8000) or ((.name//"")|test("web|ui|http|splunkweb|8000";"i")))
      | .nodePort
    ' | head -n1
)"
[[ -z "${SPLUNK_SH_NODEPORT}" || "${SPLUNK_SH_NODEPORT}" == "null" ]] && SPLUNK_SH_NODEPORT="(not found)"

# --- Read Splunk admin password from file (first line) ---
if [[ -f "${PASS_FILE}" ]]; then
  SPLUNK_ADMIN_PASSWORD="$(head -n1 "${PASS_FILE}")"
else
  SPLUNK_ADMIN_PASSWORD="(password.txt not found)"
fi

# --- Find Pod names ---
CRIBL_LEADER_PODS="$(
  kubectl -n "$CRIBL_NS" get po -l "app.kubernetes.io/instance=${CRIBL_LABEL_INSTANCE},app.kubernetes.io/name=leader" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
)"
SPLUNK_SH_PODS="$(
  kubectl -n "$SPLUNK_NS" get po -l "app.kubernetes.io/instance=${SPLUNK_SH_INSTANCE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
)"
SPLUNK_IDX_PODS="$(
  kubectl -n "$SPLUNK_NS" get po -l "app.kubernetes.io/instance=${SPLUNK_IDX_INSTANCE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
)"

[[ -z "$CRIBL_LEADER_PODS" ]] && CRIBL_LEADER_PODS="(none found)"
[[ -z "$SPLUNK_SH_PODS"    ]] && SPLUNK_SH_PODS="(none found)"
[[ -z "$SPLUNK_IDX_PODS"   ]] && SPLUNK_IDX_PODS="(none found)"

# --- Export Redis auth for this shell/session ---
export REDISCLI_AUTH="${REDIS_PASS}"

# If not sourced, warn that export will not persist in caller shell
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  PERSIST_NOTE="(run: source ${0##*/} to keep REDISCLI_AUTH in your current shell)"
else
  PERSIST_NOTE="(export persisted in this shell)"
fi

# --- Print summary ---
echo
echo "============ Post-Deploy Info ============"
echo "Public IP:            ${PUBLIC_IP:-'(unknown)'}"
echo
echo "Cribl Leader (port 9000):"
echo "  NodePort:           ${CRIBL_NODEPORT}"
[[ -n "${PUBLIC_IP}" && "${CRIBL_NODEPORT}" != "(not found)" ]] && \
  echo "  URL:                http://${PUBLIC_IP}:${CRIBL_NODEPORT}"
echo "  Pods (ns=${CRIBL_NS}):"
echo "${CRIBL_LEADER_PODS}" | sed 's/^/    - /'
echo
echo "Splunk Search Head (port 8000):"
echo "  NodePort:           ${SPLUNK_SH_NODEPORT}"
[[ -n "${PUBLIC_IP}" && "${SPLUNK_SH_NODEPORT}" != "(not found)" ]] && \
  echo "  URL:                http://${PUBLIC_IP}:${SPLUNK_SH_NODEPORT}"
echo "  Pods (ns=${SPLUNK_NS}, instance=${SPLUNK_SH_INSTANCE}):"
echo "${SPLUNK_SH_PODS}" | sed 's/^/    - /'
echo
echo "Splunk Indexer pods (ns=${SPLUNK_NS}, instance=${SPLUNK_IDX_INSTANCE}):"
echo "${SPLUNK_IDX_PODS}" | sed 's/^/    - /'
echo
echo "Splunk admin password (from ${PASS_FILE}):"
echo "  ${SPLUNK_ADMIN_PASSWORD}"
echo
echo "Redis CLI auth:"
echo "  export REDISCLI_AUTH='${REDIS_PASS}'  ${PERSIST_NOTE}"
echo "  test:  redis-cli -h 10.0.1.4 ping"
echo "=========================================="
EOF

chmod +x /home/azureuser/post_deploy_info.sh

# create outputs.conf for Splunk UF, install UF, create admin with user-seed.conf,
# and print outputs.conf for validation

# --- Config ---
UF_URL="https://download.splunk.com/products/universalforwarder/releases/10.0.0/linux/splunkforwarder-10.0.0-e8eb0c4654f8-linux-amd64.tgz"
UF_TGZ="/tmp/splunkforwarder.tgz"
UF_DIR="/opt/splunkforwarder"

SPLUNK_NS="splunk-operator"
IDX_NODEPORT_SVC="splunk-idx1-standalone-nodeports"

LOCAL_CONF_DIR="${UF_DIR}/etc/system/local"
OUTPUTS_CONF="${LOCAL_CONF_DIR}/outputs.conf"
USERSEED_CONF="${LOCAL_CONF_DIR}/user-seed.conf"

# Admin seed (used at first start)
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-splunker2024}"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have kubectl; then
  echo "ERROR: kubectl not found in PATH." >&2
  exit 1
fi

# --- Ensure splunk group & user exist ---
if ! getent group splunk >/dev/null; then
  echo "[*] Creating splunk group..."
  sudo groupadd splunk
fi

if ! id -u splunk >/dev/null 2>&1; then
  echo "[*] Creating splunk user..."
  sudo useradd -m -d /home/splunk -s /bin/bash -g splunk splunk
fi

# --- Download & extract UF ---
echo "[*] Downloading Splunk UF..."
wget -q -O "$UF_TGZ" "$UF_URL"

echo "[*] Extracting to /opt..."
sudo tar -xzf "$UF_TGZ" -C /opt/
rm -f "$UF_TGZ"

# --- Fix ownership ---
echo "[*] Ensuring splunk owns /opt/splunkforwarder..."
sudo chown -R splunk:splunk "$UF_DIR"

# --- Discover Splunk Indexer NodePort for 9997 ---
echo "[*] Discovering Splunk indexer NodePort exposed for 9997..."
SPLUNK_TCP_NODEPORT="$(
  kubectl -n "$SPLUNK_NS" get svc "$IDX_NODEPORT_SVC" -o jsonpath='{.spec.ports[?(@.name=="splunktcp")].nodePort}'
)"
if [[ -z "$SPLUNK_TCP_NODEPORT" ]]; then
  SPLUNK_TCP_NODEPORT="$(
    kubectl -n "$SPLUNK_NS" get svc "$IDX_NODEPORT_SVC" -o jsonpath='{.spec.ports[?(@.port==9997)].nodePort}'
  )"
fi
if [[ -z "$SPLUNK_TCP_NODEPORT" ]]; then
  echo "ERROR: Could not determine NodePort for Splunk TCP 9997." >&2
  exit 1
fi
echo "[*] Found NodePort: ${SPLUNK_TCP_NODEPORT}"

# --- Find a node IP (External preferred, fallback to Internal) ---
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)"
if [[ -z "$NODE_IP" ]]; then
  NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
fi
if [[ -z "$NODE_IP" ]]; then
  echo "ERROR: Could not determine a node IP." >&2
  exit 1
fi
echo "[*] Using node IP: ${NODE_IP}"

# Start Splunk
sudo -u splunk /opt/splunkforwarder/bin/splunk start --accept-license --no-prompt --answer-yes

# --- Prepare local config dir ---
sudo -u splunk mkdir -p "$LOCAL_CONF_DIR"

# --- Create user-seed.conf (admin bootstrap) ---
echo "[*] Writing ${USERSEED_CONF}..."
cat <<EOF | sudo tee "$USERSEED_CONF" >/dev/null
[user_info]
USERNAME = ${ADMIN_USER}
PASSWORD = ${ADMIN_PASS}
EOF
sudo chown splunk:splunk "$USERSEED_CONF"
sudo chmod 600 "$USERSEED_CONF"

# --- Write outputs.conf ---
echo "[*] Writing ${OUTPUTS_CONF}..."
cat <<EOF | sudo tee "$OUTPUTS_CONF" >/dev/null
[tcpout]
defaultGroup = default-autolb-group

[tcpout:default-autolb-group]
server = ${NODE_IP}:${SPLUNK_TCP_NODEPORT}

[tcpout-server://${NODE_IP}:${SPLUNK_TCP_NODEPORT}]
EOF
sudo chown splunk:splunk "$OUTPUTS_CONF"
sudo chmod 644 "$OUTPUTS_CONF"

# --- Final ownership check ---
sudo chown -R splunk:splunk "$UF_DIR"

# --- Show outputs.conf on screen for validation ---
echo
echo "===== ${OUTPUTS_CONF} ====="
sudo cat "$OUTPUTS_CONF"
echo "==========================="
echo
echo "[*] Admin user will be seeded at first start from ${USERSEED_CONF} (USERNAME=${ADMIN_USER})."
echo "[*] To start UF, run:"
echo "    sudo -u splunk ${UF_DIR}/bin/splunk start --accept-license --answer-yes"
sudo -u splunk /opt/splunkforwarder/bin/splunk restart

# Calculate how long it took for script to run
awk 'NR==1{sub(/^Script started: /,""); cmd="date -d \""$0"\" +%s"; cmd|getline s; close(cmd)}
     NR==2{sub(/^Script finished: /,""); cmd="date -d \""$0"\" +%s"; cmd|getline e; close(cmd)}
     END{diff=e-s; print int(diff/60),"minutes",diff%60,"seconds"}' /home/azureuser/timer.txt > /home/azureuser/how_long.txt