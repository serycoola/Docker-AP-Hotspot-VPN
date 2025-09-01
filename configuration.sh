#!/bin/bash

# Environment Variables for WiFi Hotspot
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


# Enable IP forwarding
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
iptables -A FORWARD -i $INTERFACE -o $OUT_CONN -j ACCEPT
iptables -A FORWARD -i $OUT_CONN -o $INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT


# Configure and start the WiFi hotspot
echo "Setting up WiFi hotspot using NMCLI..." 
nmcli connection add type wifi ifname "$INTERFACE" con-name HOTSPOT autoconnect no ssid "$AP_SSID"
nmcli connection modify HOTSPOT 802-11-wireless.mode ap 802-11-wireless.band "$BAND"
nmcli connection modify HOTSPOT wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WPA2_PASS"
nmcli connection modify HOTSPOT ipv4.addresses 10.42.0.1/24 ipv4.gateway 10.42.0.1
nmcli connection modify HOTSPOT ipv4.method manual ipv4.never-default yes
nmcli connection up HOTSPOT

echo "WiFi hotspot created with SSID: $AP_SSID on interface $INTERFACE"


# Configure and start DNSMASQ to handle DNS querries
mkdir -p /etc/dnsmasq.d/
cat > /etc/dnsmasq.d/hotspot.conf <<EOF
interface=$INTERFACE
bind-interfaces
dhcp-range=10.42.0.10,10.42.0.100,255.255.255.0,12h
dhcp-option=6,1.1.1.1,1.0.0.1
EOF

dnsmasq --conf-file=/etc/dnsmasq.d/hotspot.conf &
DNSMASQ_PID=$!

# Keep the container running
tail -f /dev/null &


# Trap SIGTERM and STOP the HOTSPOT
function cleanup {
    echo "Stopping the hotspot..."
    kill $DNSMASQ_PID 2>/dev/null || true
    nmcli connection down HOTSPOT
    nmcli connection delete HOTSPOT
    if [ "$VPN_ENABLED" -eq 1 ]; then
        kill $VPN_PID 2>/dev/null || true
        ip rule del from $HOTSPOT_SUBNET table 100 || true
        ip route flush table 100 || true
    fi
    echo "Hotspot stopped."
}

trap 'cleanup' SIGTERM

wait $!
