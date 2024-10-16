#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds gather command ************"

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

function getlogs() {
  echo "### Downloading logs..."
  scp "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*.tar*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

echo "### Gathering logs..."
timeout -s 9 15m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
cd dev-scripts

echo "Get install-gather, if there is one..."
cp /root/dev-scripts/ocp/ostest/log-bundle*.tar.gz /tmp/artifacts/log-bundle-\$HOSTNAME.tar.gz || true

echo "Get sosreport including sar data..."
sosreport --ticket-number "\$HOSTNAME" --batch -o container_log,filesys,kvm,libvirt,logs,networkmanager,podman,processor,rpm,sar,virsh,yum --tmp-dir /tmp/artifacts

echo "Get libvirt logs..."
tar -czC "/var/log/libvirt/qemu" -f "/tmp/artifacts/libvirt-logs-\$HOSTNAME.tar.gz" --transform "s?^\.?libvirt-logs-\$HOSTNAME?" .

echo "Get the bootstrap logs if it is around and we didn't already collect them..."
if ! compgen -G "/root/dev-scripts/ocp/ostest/log-bundle*.tar.gz" > /dev/null 2>&1
then
  . common.sh
  . network.sh
  . utils.sh

  ssh -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' core@\$BOOTSTRAP_PROVISIONING_IP TAR_FILE=/tmp/log-bundle-bootstrap.tar.gz sudo -E /usr/local/bin/installer-gather.sh --id bootstrap &&
  scp -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' core@\$(wrap_if_ipv6 \$BOOTSTRAP_PROVISIONING_IP):/tmp/log-bundle-bootstrap.tar.gz /tmp/artifacts/log-bundle-bootstrap.tar.gz || true
fi

echo "Get the proxy logs..."
if podman container exists external-squid
then
  mkdir -p /tmp/squid-logs-$NAMESPACE
  podman cp external-squid:/var/log/squid/access.log /tmp/squid-logs-$NAMESPACE || true
  podman cp external-squid:/var/log/squid/cache.log /tmp/squid-logs-$NAMESPACE || true
  tar -czC "/tmp" -f "/tmp/artifacts/squid-logs-$NAMESPACE.tar.gz" squid-logs-$NAMESPACE/
fi
EOF
