#!/bin/bash

# === Environment Variables ===
AP_SSID=${AP_SSID:-"VPN-HOTSPOT"}
WPA2_PASS=${WPA2_PASS:-"password"}
INTERFACE=${INTERFACE:-"wlan0"}
OUTGOINGS=${OUTGOINGS:-"tun0"}

HOTSPOT_SUBNET=${HOTSPOT_SUBNET:-"10.42.0.0/24"}

VPN_USER=${VPN_USER:-"vpnuser"}
VPN_PASS=${VPN_PASS:-"vpnpass"}
VPN_CONFIG=${VPN_CONFIG:-"default"}
VPN_PATH=${VPN_PATH:-"/etc/openvpn/configs"}

# === Enable IP Forwarding ===
echo 1 > /proc/sys/net/ipv4/ip_forward

# === Start NetworkManager manually (no systemd) ===
echo "Starting NetworkManager..."
NetworkManager --no-daemon &
NM_PID=$!
sleep 5  # let it initialize

# === NM dnsmasq upstream DNS (resolves via VPN) ===
mkdir -p /etc/NetworkManager/dnsmasq.d
cat > /etc/NetworkManager/dnsmasq.d/hotspot.conf <<EOF
server=1.1.1.1
server=8.8.8.8
EOF

# === iptables NAT for VPN ===
iptables -t nat -A POSTROUTING -s $HOTSPOT_SUBNET -o $OUTGOINGS -j MASQUERADE
iptables -A FORWARD -s $HOTSPOT_SUBNET -o $OUTGOINGS -j ACCEPT
iptables -A FORWARD -d $HOTSPOT_SUBNET -m state --state RELATED,ESTABLISHED -j ACCEPT

# === OpenVPN Setup ===
VPN_FILE=$(find $VPN_PATH -type f -name "*${VPN_CONFIG}*.ovpn" | head -n 1)
if [ -z "$VPN_FILE" ]; then
  echo "VPN configuration file not found for query: $VPN_CONFIG"
  exit 1
fi

mkdir -p /etc/openvpn
echo "$VPN_USER" > /etc/openvpn/auth.conf
echo "$VPN_PASS" >> /etc/openvpn/auth.conf
chmod 600 /etc/openvpn/auth.conf

echo "Connecting to VPN..."
openvpn --config "${VPN_FILE}" \
  --auth-nocache \
  --auth-user-pass /etc/openvpn/auth.conf \
  --route-nopull &

VPN_PID=$!
sleep 15  # wait for VPN connection

# === Policy Routing: hotspot subnet → VPN ===
ip rule add from $HOTSPOT_SUBNET table 100 priority 100
ip route add default dev $OUTGOINGS table 100

# === Start NM Hotspot ===
echo "Creating hotspot..."
nmcli device wifi hotspot con-name HOTSPOT band bg ifname $INTERFACE ssid $AP_SSID password $WPA2_PASS

# === Keep script alive ===
tail -f /dev/null &

# === Cleanup ===
function cleanup {
    echo "Stopping hotspot..."
    nmcli connection down HOTSPOT
    nmcli connection delete HOTSPOT

    ip rule del from $HOTSPOT_SUBNET table 100
    ip route flush table 100

    kill $VPN_PID $NM_PID 2>/dev/null || true
    echo "Hotspot stopped."
}
trap 'cleanup' SIGTERM SIGINT

wait $!
