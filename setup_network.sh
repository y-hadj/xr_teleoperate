#!/bin/bash
# Turn the G1's WiFi (wlan0) into a hotspot, or back into a normal WiFi client.
# The robot's WiFi card can't do both at once. The hotspot is not started at boot.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
    "")    MODE="on" ;;
    --off) MODE="off" ;;
    *)     die "Usage: $0 [--off]" ;;
esac

JETSON_USER="unitree"
JETSON_IP="192.168.123.164"
TMP_DIR="/tmp/g1_hotspot_debs"
DEB_DIR="$TMP_DIR/debs"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh_g1_%h -o ControlPersist=60"

SSID="G1-Hotspot"
PASS="g1robot123"
AP_IP="192.168.4.1"

DEB_URLS=(
    "http://ports.ubuntu.com/pool/universe/w/wpa/hostapd_2.9-1ubuntu4.6_arm64.deb"
    "http://ports.ubuntu.com/pool/main/d/dnsmasq/dnsmasq-base_2.80-1.1ubuntu1_arm64.deb"
    "http://ports.ubuntu.com/pool/main/d/dnsmasq/dnsmasq-utils_2.80-1.1ubuntu1_arm64.deb"
)

echo "=== [0/4] Pre-run checks ==="

# check if the robot is connected via ethernet 
if ! ping -c 2 -W 2 "$JETSON_IP" >/dev/null 2>&1; then
    if [ "$MODE" = "off" ] && ping -c 2 -W 2 "$AP_IP" >/dev/null 2>&1; then
        JETSON_IP="$AP_IP"
    else
        die "Robot $JETSON_IP is unreachable. You may need to run ./connect_ethernet.sh first."
    fi
fi
JETSON_SSH="$JETSON_USER@$JETSON_IP"

# if the host holds the robot's ip, refuse the resulting connection to avoid loopbacks
if ip route get "$JETSON_IP" 2>/dev/null | grep -qw "dev lo"; then
    die "Route to $JETSON_IP points at loopback — this PC is holding the robot's IP ($JETSON_IP). Remove it: sudo ip addr del $JETSON_IP/24 dev <iface>, then re-run connect_ethernet.sh."
fi

# check key authentification
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 $SSH_OPTS "$JETSON_SSH" "exit" 2>/dev/null; then
    die "Robot is reachable but passwordless SSH is not set up. Run: ssh-copy-id $JETSON_SSH"
fi
echo "Robot reachable at $JETSON_IP and key auth OK."

LOCAL_TMP=$(mktemp -d)

# ------------------------------------------------------------------ hotspot OFF
if [ "$MODE" = "off" ]; then
    cat > "$LOCAL_TMP/hotspot_off.sh" << 'EOF'
#!/bin/bash
set -uo pipefail

echo "--- Stopping hotspot ---"
sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl disable hostapd 2>/dev/null || true
sudo pkill -x dnsmasq 2>/dev/null || true
sudo ip addr flush dev wlan0 2>/dev/null || true

echo "--- Giving wlan0 back to NetworkManager ---"
sudo nmcli device set wlan0 managed yes
sleep 3
PREV=$(cat /etc/g1-hotspot/previous-connection 2>/dev/null || true)
if [ -n "$PREV" ]; then
    echo "--- Reconnecting to '$PREV' ---"
    sudo nmcli connection up "$PREV" || echo "WARNING: could not reconnect to '$PREV' — NetworkManager will retry known networks on its own."
else
    echo "--- No remembered WiFi: letting NetworkManager connect to a known network ---"
    sudo nmcli device connect wlan0 || true
fi

echo ""
nmcli -t -f DEVICE,STATE,CONNECTION device status | grep '^wlan0:' || true
ip -4 addr show wlan0 | grep inet || true
echo "=== Hotspot OFF ==="
EOF
    scp $SSH_OPTS "$LOCAL_TMP/hotspot_off.sh" "$JETSON_SSH:~/hotspot_off.sh" || die "scp failed"
    if [ "$JETSON_IP" = "$AP_IP" ]; then
        # we are talking through the hotspot itself: the link drops as soon as it stops,
        # so run detached on the robot and let it finish on its own
        echo "=== Turning hotspot off (enter the robot's sudo password when prompted) ==="
        ssh -t $SSH_OPTS "$JETSON_SSH" "sudo -v && (sudo setsid bash ~/hotspot_off.sh > /tmp/hotspot_off.log 2>&1 < /dev/null &) ; sleep 1"
        echo ">>>> Hotspot is shutting down; this connection will drop. The robot reconnects to its previous WiFi (log on the robot: /tmp/hotspot_off.log)."
    else
        echo "=== Turning hotspot off (enter the robot's sudo password when prompted) ==="
        ssh -t $SSH_OPTS "$JETSON_SSH" "sudo bash ~/hotspot_off.sh; rc=\$?; rm -f ~/hotspot_off.sh; exit \$rc" \
            || die "Turning the hotspot off failed (see above)"
        echo ">>>> Hotspot off. The robot is back on its normal WiFi."
    fi
    rm -rf "$LOCAL_TMP"
    exit 0
fi

# ------------------------------------------------------------------ hotspot ON
# download debs on host
echo "=== [1/4] Downloading arm64 debs on host ==="
rm -rf "$TMP_DIR"
mkdir -p "$DEB_DIR"
cd "$DEB_DIR"
for url in "${DEB_URLS[@]}"; do
    wget -q "$url" -O "$(basename "$url")" || die "Failed to download $url"
done

# transfer them to Jetson /tmp
echo "=== [2/4] Transferring to Jetson ==="
ssh $SSH_OPTS "$JETSON_SSH" "mkdir -p /tmp/hotspot_debs" || die "Cannot SSH"
scp $SSH_OPTS "$DEB_DIR"/*.deb "$JETSON_SSH:/tmp/hotspot_debs/" || die "scp failed"

# 3. write remote setup script
echo "=== [3/4] Writing remote setup script ==="
cat > "$LOCAL_TMP/remote_setup.sh" << 'EOF'
#!/bin/bash
set -eo pipefail
AP_IP="192.168.4.1"
SSID="G1-Hotspot"
PASS="g1robot123"

echo "--- Unblocking WiFi ---"
sudo rfkill unblock wifi 2>/dev/null || true
sudo ip link set wlan0 up 2>/dev/null || true

echo "--- Installing debs ---"
cd /tmp/hotspot_debs
sudo dpkg -i *.deb || true

echo "--- Disconnecting wlan0 from its current WiFi ---"
# remember the network so './setup_network.sh --off' can reconnect to it
sudo mkdir -p /etc/g1-hotspot
PREV=$(nmcli -t -f GENERAL.CONNECTION device show wlan0 2>/dev/null | cut -d: -f2- || true)
if [ -n "$PREV" ] && [ "$PREV" != "--" ]; then
    echo "wlan0 is connected to '$PREV' — disconnecting it (reconnect later with: ./setup_network.sh --off)"
    echo "$PREV" | sudo tee /etc/g1-hotspot/previous-connection > /dev/null
    sudo nmcli device disconnect wlan0 || true
else
    echo "wlan0 is not connected to any WiFi."
fi
# keep NetworkManager off wlan0 while the hotspot runs, otherwise it reconnects and kicks hostapd off.
# runtime only: after a reboot NetworkManager takes wlan0 back
sudo nmcli device set wlan0 managed no
sudo rm -f /etc/NetworkManager/conf.d/99-g1-hotspot.conf

echo "--- Configuring dnsmasq ---"
# DHCP only (port=0: no DNS server), so it doesn't clash with the robot's own DNS (systemd-resolved)
sudo tee /etc/dnsmasq.conf > /dev/null << EOC
interface=wlan0
bind-interfaces
port=0
dhcp-range=192.168.4.2,192.168.4.100,255.255.255.0,24h
EOC

echo "--- Configuring hostapd ---"
sudo mkdir -p /etc/hostapd
sudo tee /etc/hostapd/hostapd.conf > /dev/null << EOC
interface=wlan0
driver=nl80211
country_code=FR
ieee80211d=1
ssid=$SSID
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOC

sudo sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

echo "--- Setting up wlan0 ---"
sudo ip addr flush dev wlan0 2>/dev/null || true
sudo ip addr add $AP_IP/24 dev wlan0
sudo ip link set wlan0 up

echo "--- Enabling IP forwarding ---"
sudo sysctl -w net.ipv4.ip_forward=1
sudo sed -i '/net.ipv4.ip_forward=/c\net.ipv4.ip_forward=1' /etc/sysctl.conf

echo "--- Starting services ---"
sudo systemctl unmask hostapd 2>/dev/null || true
# not enabled at boot: a reboot gives the robot its normal WiFi back
sudo systemctl disable hostapd 2>/dev/null || true
sudo systemctl restart hostapd || true
sleep 3
if ! systemctl is-active --quiet hostapd; then
    echo "ERROR: hostapd failed to start, no hotspot. Last log lines:"
    sudo journalctl -u hostapd -n 30 --no-pager
    echo "Restore the normal WiFi with: ./setup_network.sh --off"
    exit 1
fi

sudo pkill -x dnsmasq 2>/dev/null || true
sleep 1
# if an old dnsmasq (older versions of this script) held port 53: let systemd-resolved take it back
sudo systemctl try-restart systemd-resolved 2>/dev/null || true
sudo dnsmasq

echo ""
echo "========================================"
echo " Hotspot configured!"
echo " SSID: $SSID"
echo " Password: $PASS"
echo " Jetson IP: $AP_IP"
echo "========================================"
EOF

# 4. transfer and execute it on Jetson
echo "=== [4/4] Executing on Jetson (enter sudo password when prompted) ==="
scp $SSH_OPTS "$LOCAL_TMP/remote_setup.sh" "$JETSON_SSH:~/hotspot_setup.sh"
ssh -X -t $SSH_OPTS "$JETSON_SSH" "sudo bash ~/hotspot_setup.sh"

rm -rf "$TMP_DIR" "$LOCAL_TMP"
ssh $SSH_OPTS "$JETSON_SSH" "rm -rf /tmp/hotspot_debs ~/hotspot_setup.sh" || true

echo ">>>> Script terminated with success.You can now disconnect ethernet connection and connect to G1-Hotspot."
echo ">>>> To give the robot its normal WiFi back later: ./setup_network.sh --off"
