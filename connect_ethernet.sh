#!/bin/bash

set -uo pipefail
source "$(dirname "$0")/g1_common.sh"

IFACE="${1:-}"

# wired candidates: skip loopback, wifi, docker/virtual/bridge/tunnel interfaces
wired_ifaces() {
    local i
    for i in /sys/class/net/*; do
        i=$(basename "$i")
        case "$i" in lo|wl*|docker*|veth*|br-*|virbr*|tun*|tap*|l4tbr*) continue ;; esac
        [ -d "/sys/class/net/$i/wireless" ] && continue
        echo "$i"
    done
}

# 1) keep the host away from the robot's addr
if [ "$HOST_IP" = "$G1_IP" ]; then
    die "HOST_IP is set to the robot's IP ($G1_IP). This causes an IP conflict where you SSH into your own machine. Pick a different HOST_IP."
fi

# 2) pick the interface
if [ -z "$IFACE" ]; then
    for i in $(wired_ifaces); do
        sudo ip link set "$i" up 2>/dev/null || true   # carrier is only readable when up
    done
    sleep 2
    linked=()
    for i in $(wired_ifaces); do
        [ "$(cat /sys/class/net/$i/carrier 2>/dev/null)" = "1" ] && linked+=("$i")
    done
    [ "${#linked[@]}" -gt 0 ] || die "No wired interface has a link. Candidates: $(wired_ifaces | tr '\n' ' ')
Check: cable plugged into the robot and this PC? robot powered on? USB-ethernet adapter seated?"

    if [ "${#linked[@]}" -eq 1 ]; then
        IFACE="${linked[0]}"
    else
        # several cables: prefer the one already on the robot subnet, then one without any IPv4 (i.e. not the office LAN)
        for i in "${linked[@]}"; do
            ip -4 addr show dev "$i" | grep -qw "$HOST_IP" && { IFACE="$i"; break; }
        done
        if [ -z "$IFACE" ]; then
            for i in "${linked[@]}"; do
                ip -4 addr show dev "$i" | grep -q inet || { IFACE="$i"; break; }
            done
        fi
        [ -n "$IFACE" ] || die "Several wired interfaces have a link (${linked[*]}). Pass the one cabled to the robot: ./connect_ethernet.sh <iface>"
    fi
    echo "Auto-detected wired interface with link: $IFACE"
elif ! ip link show "$IFACE" &>/dev/null; then
    die "Interface $IFACE not found. Available wired interfaces: $(wired_ifaces | tr '\n' ' ')"
fi

echo "=== Configuring $IFACE for the G1 link ==="

# 3) take the interface out of NetworkManager so it doesnt fight the host's static ip then bring the iface up
sudo nmcli device set "$IFACE" managed no 2>/dev/null || true
sudo ip link set "$IFACE" up

# 4) the robot subnet must live on this interface only
for other in $(ip -o -4 addr show | awk -v ip="$HOST_IP" '$4 ~ "^"ip"/" {print $2}'); do
    if [ "$other" != "$IFACE" ]; then
        echo "Removing stale $HOST_IP from $other."
        sudo ip addr del "$HOST_IP/$SUBNET" dev "$other" 2>/dev/null || true
    fi
done
# 5) never hold the robot's ip ourselves
for other in $(ip -o -4 addr show | awk -v ip="$G1_IP" '$4 ~ "^"ip"/" {print $2}'); do
    echo "Found robot IP $G1_IP wrongly assigned to $other — removing it."
    sudo ip addr del "$G1_IP/$SUBNET" dev "$other" 2>/dev/null || true
done

if ip -4 addr show dev "$IFACE" | grep -qw "$HOST_IP"; then
    echo "$HOST_IP already assigned to $IFACE — skipping add."
else
    echo "Assigning $HOST_IP/$SUBNET to $IFACE."
    sudo ip addr add "$HOST_IP/$SUBNET" dev "$IFACE"
fi

# 6) the robot must be routed through this interface
route_dev=$(ip route get "$G1_IP" 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}')
if [ "$route_dev" != "$IFACE" ]; then
    die "Route to $G1_IP goes via '$route_dev', not $IFACE. Another interface (VPN, docker network, ...) is using 192.168.123.0/24 — remove it, then re-run."
fi

# 7) wait for the robot (it may still be booting)
echo "=== Waiting for robot at $G1_IP ==="
for _ in $(seq 1 30); do
    if ping -c 1 -W 2 "$G1_IP" >/dev/null 2>&1; then
        echo ""
        echo "=== Link OK on $IFACE. ==="
        exit 0
    fi
    sleep 2
done
die "No reply from $G1_IP after ~60s. Check: robot powered on? cable seated? correct interface ($IFACE)?"
