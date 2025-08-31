#!/bin/bash

# Environment Variables for WIFI Hotspot
AP_SSID=${AP_SSID:-"VPN-HOTSPOT"}
WPA2_PASS=${WPA2_PASS:-"password"}
INTERFACE=${INTERFACE:-"wlan0"}
OUTGOINGS=${OUTGOINGS:-"tun0"}
BAND=${BAND:-"bg"}

HOTSPOT_SUBNET=${HOTSPOT_SUBNET:-"10.42.0.0/24"}

# Environment Variables for VPN
VPN_USER=${VPN_USER:-"vpnuser"}
VPN_PASS=${VPN_PASS:-"vpnpass"}
VPN_CONFIG=${VPN_CONFIG:-"default"}
VPN_PATH=${VPN_PATH:-"/etc/openvpn/configs"}


# Enable IP Forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward


# Find the first VPN configuration file that matches VPN_CONFIG
VPN_FILE=$(find $VPN_PATH -type f -name "*${VPN_CONFIG}*.ovpn" | head -n 1)
if [ -z "$VPN_FILE" ]; then
  echo "VPN configuration file not found for query: $VPN_CONFIG"
  echo "Continuing without VPN..."
  VPN_ENABLED=0
else
  VPN_ENABLED=1
fi


if [ "$VPN_ENABLED" -eq 1 ]; then
    # Write VPN credentials to auth.conf
    mkdir -p /etc/openvpn
    echo "$VPN_USER" > /etc/openvpn/auth.conf
    echo "$VPN_PASS" >> /etc/openvpn/auth.conf
    chmod 600 /etc/openvpn/auth.conf
    
    # Configure and connect to VPN
    echo "Connecting to VPN..."
    openvpn --config ${VPN_FILE} \
      --auth-nocache \
      --auth-user-pass /etc/openvpn/auth.conf \
      --route-nopull &
    VPN_PID=$!
    sleep 10

    echo "WiFi hotspot is now connected to the following VPN config:"
    echo "$VPN_FILE"

    # Policy Routing: hotspot subnet → VPN
    ip rule add from $HOTSPOT_SUBNET table 100 priority 100
    ip route add default dev $OUTGOINGS table 100
fi


# Set up NAT (route WiFi traffic through tun0 on the HOTSPOT_SUBNET only)
if [ "$VPN_ENABLED" -eq 1 ]; then
    OUT_CONN=$OUTGOINGS  # usually tun0
else
    # Find the default interface for internet
    OUT_CONN=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
fi
iptables -t nat -A POSTROUTING -s $HOTSPOT_SUBNET -o $OUT_CONN -j MASQUERADE
iptables -A FORWARD -s $HOTSPOT_SUBNET -o $OUT_CONN -j ACCEPT
iptables -A FORWARD -d $HOTSPOT_SUBNET -m state --state RELATED,ESTABLISHED -j ACCEPT


# Set interface up and check AP mode
ip link set "$INTERFACE" down
iw dev "$INTERFACE" set type __ap || true
ip addr flush dev "$INTERFACE"
ip addr add 10.42.0.1/24 dev "$INTERFACE"
ip link set "$INTERFACE" up


# Configure and start the WiFi hotspot
mkdir -p /etc/hostapd
cat > /etc/hostapd/hotspot.conf <<EOF
interface=$INTERFACE
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$WPA2_PASS
max_num_sta=10
EOF

hostapd /etc/hostapd/hotspot.conf &
HOSTAPD_PID=$!

echo "WiFi hotspot created with SSID: $AP_SSID on interface $INTERFACE"
sleep 5


# Configure and start DNSMASQ to handle DNS querries
mkdir -p /etc/NetworkManager/dnsmasq.d/
cat > /etc/NetworkManager/dnsmasq.d/hotspot.conf <<EOF
interface=$INTERFACE
bind-interfaces
dhcp-range=10.42.0.10,10.42.0.100,255.255.255.0,12h
dhcp-option=6,1.1.1.1,8.8.8.8
EOF

dnsmasq --conf-file=/etc/NetworkManager/dnsmasq.d/hotspot.conf &
DNSMASQ_PID=$!


# Keep the container running
tail -f /dev/null &


# Trap SIGTERM and STOP the HOTSPOT
function cleanup {
    echo "Stopping hotspot..."
    kill $HOSTAPD_PID $DNSMASQ_PID 2>/dev/null || true
    if [ "$VPN_ENABLED" -eq 1 ]; then
        kill $VPN_PID 2>/dev/null || true
        ip rule del from $HOTSPOT_SUBNET table 100 || true
        ip route flush table 100 || true
    fi
    echo "Hotspot stopped."
}
trap 'cleanup' SIGTERM SIGINT

wait $!
