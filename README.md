# Kube-Splunk-Cribl Starter Kit

A streamlined, single-node Kubernetes starter that provisions Splunk Enterprise (via Splunk Operator), Cribl Stream (leader + worker group), and Redis on Ubuntu 22.04 — plus helper scripts, example configs, and Terraform for Azure infrastructure.

## What this repo does
- Boots a controller node with containerd/runc/CNI and initializes a K8s control plane
- Installs Splunk Operator and deploys a Search Head and Indexer (with NodePort access)
- Seeds distributed search trust and exposes Splunk services for quick testing
- Installs Cribl Stream (leader + worker group) with example pipelines (Redis HGET/HSET), routes, jobs, and outputs
- Configures Redis with auth and custom bind IP
- Includes a post-deploy helper to print all useful URLs, ports, passwords, and quick checks
- Ships Terraform to create the Azure VM, VNet, Subnet, NSG association, and public IP

> **Security note:** The examples intentionally include placeholder tokens/passwords and a sample Azure subscription/tenant in Terraform. Replace all secrets with your own **before** running and never commit real credentials.

## Prereqs
- Ubuntu 22.04 VM (public IP recommended)
- Internet egress (downloads Helm charts, CRDs, images)
- `curl`, `jq`, `kubectl`, and `helm` (the install script bootstraps what’s missing)
- Azure credentials if you plan to use the Terraform module

## Quick start
1. Review **scripts/install-kube.sh** and replace any placeholder values (passwords, tokens, IPs).
2. Run the script on your Ubuntu node (as a sudo-capable user).
3. After the install completes, run **scripts/post_deploy_info.sh** to print endpoints and quick checks.
4. Log into:
   - Splunk Web (NodePort)
   - Cribl UI (NodePort)
   - Splunk HEC/TCP and mgmt services (see post-deploy output)
5. (Optional) Use **terraform/** to provision the VM and networking in Azure.

## Directory layout
- **scripts/** — Install and post-deploy helper scripts
- **kubernetes/** — Static manifests for Splunk/Operator, CNI, storage, and metrics server
- **helm/** — Values files for Helm-based apps (e.g., Cribl leader/worker-group)
- **cribl/** — Example pipelines (Redis HGET/HSET), jobs, routes, secrets, outputs
- **redis/** — Example redis.conf with bind/ip and password
- **terraform/** — Azure VM, VNet, subnet, NSG, public IP; variables and outputs
- **docs/** — Architecture and operational notes (optional)

## Inputs & outputs (at a glance)
- Splunk SH Web: `http://<node-public-ip>:<nodeport-8000>`
- Cribl Leader UI: `http://<node-public-ip>:<nodeport-9000>`
- Splunk TCP (S2S): `:<NodePort>`
- Splunk HEC: `:<NodePort>`
- Splunk Mgmt: `:<NodePort>`

## Customization tips
- **StorageClass**: local-path by default; switch to your CSI driver in `kubernetes/*` and values files
- **TLS**: enable TLS for Splunk/Cribl/HEC in production
- **Passwords/Tokens**: rotate and store in a secrets manager
- **Scaling**: bump resources/replicas for non-dev use

## Install duration (plan ~15 minutes)

Provisioning and configuration typically take **about 15 minutes** on a D8ds_v6 or similar VM with good internet connectivity.  

Approximate breakdown:
- **Base dependencies + container runtime:** 2–4 minutes  
- **Kubernetes initialization (kubeadm + CNI):** 2–3 minutes  
- **Helm setup + CRDs + app charts:** 1–2 minutes  
- **Pulling container images (Splunk, Cribl, Redis, etc.):** 6–10 minutes  
- **Final configuration and startup checks:** 1–3 minutes  

> The first run takes the longest since container images need to be pulled.  
> Re-runs on the same host are faster due to caching.  
> You can monitor progress using:  
> `kubectl get pods -A -w`  

---

## Required inbound ports

Ensure the following inbound ports are open on your VM’s **Network Security Group (NSG)** or firewall to allow full functionality:

| Purpose | Port(s) | Protocol | Description |
|----------|----------|-----------|--------------|
| SSH access | 22 | TCP | Remote admin access to the VM |
| HTTP / HTTPS | 80, 443 | TCP | Optional — for web dashboards or future ingress controllers |
| Redis | 6379 | TCP | Required for Cribl pipelines using Redis integration |
| Kubernetes NodePorts | 30000–32767 | TCP | Required for Splunk Web, Cribl UI, HEC, and other exposed services |

> Tip: After deployment, run `scripts/post_deploy_info.sh` to view the exact URLs and NodePorts assigned to Splunk and Cribl.

---

## Teardown (high level)
- Use scripts/teardown.sh to deprovision resources
- Uninstall Helm releases (Cribl, Splunk charts)
- Delete K8s namespaces and CRDs created for the operator
- `kubeadm reset -f` on the node if this is a lab
- Remove containerd/CNI only if the node is solely for this lab

---

### Disclaimer
This repo is intended for lab, demo, and learning scenarios. Validate and harden all configurations (RBAC, TLS, network policies, storage, and secrets) before any production use.