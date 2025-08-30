#!/bin/bash
set -e

# Configuration Variables
AP_SSID=${AP_SSID:-"VPN-HOTSPOT"}
WPA2_PASS=${WPA2_PASS:-"password"}
INTERFACE=${INTERFACE:-"wlan0"}
OUTGOINGS=${OUTGOINGS:-"tun0"}
BAND=${BAND:-"bg"}

HOTSPOT_SUBNET=${HOTSPOT_SUBNET:-"10.42.0.0/24"}

VPN_USER=${VPN_USER:-"vpnuser"}
VPN_PASS=${VPN_PASS:-"vpnpass"}
VPN_CONFIG=${VPN_CONFIG:-"default"}
VPN_PATH=${VPN_PATH:-"/etc/openvpn/configs"}


# Functions
cleanup() {
    echo "Stopping hotspot..."
    nmcli connection down HOTSPOT 2>/dev/null || true
    nmcli connection delete HOTSPOT 2>/dev/null || true

    echo "Removing ip rules and routes..."
    ip rule del from $HOTSPOT_SUBNET table 100 || true
    ip route flush table 100 || true

    echo "Flushing iptables..."
    iptables -t nat -F
    iptables -F

    echo "Stopping dnsmasq..."
    pkill dnsmasq 2>/dev/null || true

    echo "Cleanup done."
}
trap cleanup EXIT SIGTERM SIGINT


# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward


# Start dnsmasq for DHCP + DNS
cat > /etc/dnsmasq-hotspot.conf <<EOF
interface=$INTERFACE
dhcp-range=10.42.0.10,10.42.0.250,255.255.255.0,12h
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8
bind-interfaces
EOF

dnsmasq --conf-file=/etc/dnsmasq-hotspot.conf


# iptables NAT only for hotspot → VPN
iptables -t nat -A POSTROUTING -s $HOTSPOT_SUBNET -o $OUTGOINGS -j MASQUERADE
iptables -A FORWARD -s $HOTSPOT_SUBNET -o $OUTGOINGS -j ACCEPT
iptables -A FORWARD -d $HOTSPOT_SUBNET -m state --state RELATED,ESTABLISHED -j ACCEPT


# Start OpenVPN
VPN_FILE=$(find $VPN_PATH -type f -name "*${VPN_CONFIG}*.ovpn" | head -n 1)
if [ -z "$VPN_FILE" ]; then
  echo "VPN configuration file not found for query: $VPN_CONFIG"
  exit 1
fi

mkdir -p /etc/openvpn
echo "$VPN_USER" > /etc/openvpn/auth.conf
echo "$VPN_PASS" >> /etc/openvpn/auth.conf
chmod 600 /etc/openvpn/auth.conf

echo "Starting OpenVPN..."
openvpn --config "$VPN_FILE" \
  --auth-nocache \
  --auth-user-pass /etc/openvpn/auth.conf \
  --route-nopull &
VPN_PID=$!
sleep 15


# Policy routing: hotspot subnet → VPN
ip rule add from $HOTSPOT_SUBNET table 100 priority 100
ip route add default dev $OUTGOINGS table 100


# Start WiFi Hotspot via NetworkManager
nmcli device wifi hotspot con-name HOTSPOT band $BAND ifname $INTERFACE ssid $AP_SSID password $WPA2_PASS
echo "Hotspot $AP_SSID started on interface $INTERFACE"


# Keep container running
wait $VPN_PID
