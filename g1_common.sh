# Shared settings/helpers for the G1 setup scripts (sourced, not executed).
# Every value can be overridden from the environment, e.g.  G1_IP=192.168.123.164 ./bootstrap_g1.sh

G1_USER="${G1_USER:-unitree}"
G1_IP="${G1_IP:-192.168.123.164}"        # Jetson (PC2) on every G1
HOST_IP="${HOST_IP:-192.168.123.100}"    # this PC on the robot's wired subnet
SUBNET="24"
G1_SSH="$G1_USER@$G1_IP"

# one shared, self-healing SSH connection for all scripts
SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    -o ControlMaster=auto -o ControlPath="/tmp/ssh_g1_%r@%h" -o ControlPersist=120
)

die() { echo "ERROR: $*" >&2; exit 1; }

# close a leftover shared connection from an earlier (interrupted) run
g1_close_ssh() {
    ssh -o ControlPath="/tmp/ssh_g1_%r@%h" -O exit "$G1_SSH" 2>/dev/null || true
}

# Wait until sshd on the robot answers then make sure the stored host key belongs to *this* robot
# (because all G1s share the same IP but with diff key)
g1_prepare_ssh() {
    local keys="" waited=0
    echo "--- Waiting for SSH on $G1_IP ---"
    while :; do
        keys=$(ssh-keyscan -T 5 "$G1_IP" 2>/dev/null | awk '{print $3}')
        [ -n "$keys" ] && break
        [ "$waited" -ge 90 ] && die "Robot $G1_IP pings but its SSH server does not answer (no banner) after ${waited}s. sshd on the Jetson is hung — check it from a local terminal on the robot ('sudo systemctl restart ssh')."
        sleep 5; waited=$((waited + 5))
    done

    local stored
    stored=$(ssh-keygen -F "$G1_IP" 2>/dev/null | grep -v '^#' | awk '{print $3}')
    if [ -n "$stored" ] && ! grep -qxFf <(echo "$keys") <<< "$stored"; then
        echo "--- Stored SSH host key for $G1_IP is from another (or reflashed) robot — replacing it ---"
        ssh-keygen -R "$G1_IP" >/dev/null 2>&1
    fi
    g1_close_ssh
}
