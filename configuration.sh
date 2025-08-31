#!/bin/bash

# Environment Variables
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



# Enable IP Forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward


# OpenVPN Setup
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
openvpn --config ${VPN_FILE} \
  --auth-nocache \
  --auth-user-pass /etc/openvpn/auth.conf \
  --route-nopull &

VPN_PID=$!
sleep 15


# Policy Routing: hotspot subnet → VPN
ip rule add from $HOTSPOT_SUBNET table 100 priority 100
ip route add default dev $OUTGOINGS table 100

# iptables NAT
iptables -t nat -A POSTROUTING -s $HOTSPOT_SUBNET -o $OUTGOINGS -j MASQUERADE
iptables -A FORWARD -s $HOTSPOT_SUBNET -o $OUTGOINGS -j ACCEPT
iptables -A FORWARD -d $HOTSPOT_SUBNET -m state --state RELATED,ESTABLISHED -j ACCEPT

# Start Hostapd
mkdir -p /etc/hostapd
cat > /etc/hostapd/hotspot.conf <<EOF
interface=$INTERFACE
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=6
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$WPA2_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

hostapd /etc/hostapd/hotspot.conf &
HOSTAPD_PID=$!

# Start Dnsmasq
mkdir -p /etc/dnsmasq
cat > /etc/dnsmasq/hotspot.conf <<EOF
interface=$INTERFACE
dhcp-range=10.42.0.10,10.42.0.50,255.255.255.0,12h
dhcp-option=6,1.1.1.1,8.8.8.8
EOF

dnsmasq -C /etc/dnsmasq/hotspot.conf &
DNSMASQ_PID=$!


# Keep Alive
tail -f /dev/null &

function cleanup {
    echo "Stopping hotspot..."
    kill $HOSTAPD_PID $DNSMASQ_PID $VPN_PID 2>/dev/null || true
    ip rule del from $HOTSPOT_SUBNET table 100
    ip route flush table 100
    echo "Hotspot stopped."
}
trap 'cleanup' SIGTERM

wait $!
