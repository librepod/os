# Deploy a machine to a host via deploy-rs
# Requires deploy-rs to be available (consumer's responsibility)
deploy machine hostname:
  deploy ./#{{machine}} --hostname {{hostname}}

# Copy kubeconfig from a remote host
copy-kube-config-from host:
  scp root@{{host}}:/etc/rancher/k3s/k3s.yaml ~/.kube/{{host}}.config
  sed -i 's/127.0.0.1/{{host}}/g' ~/.kube/{{host}}.config
  cp ~/.kube/{{host}}.config ~/.kube/config
  kubectx {{host}}=default

# Reset K3S cluster and start fresh (unmounts kubelet, deletes all data)
# Prerequisites: k3s service must already be disabled and stopped
# WARNING: This destroys all cluster state
reset-k3s host:
  ssh root@{{host}} bash -c '\
    set -e; \
    if systemctl is-enabled k3s >/dev/null 2>&1 || systemctl is-active k3s >/dev/null 2>&1; then \
      echo "ERROR: k3s service is still present. Disable it first (services.k3s.enable = false) and redeploy."; \
      exit 1; \
    fi; \
    echo "Unmounting kubelet..."; \
    KUBELET_PATH=$$(mount | grep kubelet | cut -d" " -f3); \
    $${KUBELET_PATH:+umount $$KUBELET_PATH}; \
    echo "Deleting k3s data..."; \
    rm -rf /etc/rancher/{k3s,node}; \
    rm -rf /var/lib/{rancher/k3s,kubelet,longhorn,etcd,cni}; \
    echo "Cluster reset complete."; \
  '
