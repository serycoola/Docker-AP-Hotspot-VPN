#!/bin/bash

# Environment Variables
AP_SSID=${AP_SSID:-"VPN-HOTSPOT"}
WPA2_PASS=${WPA2_PASS:-"password"}
INTERFACE=${INTERFACE:-"wlan0"}
OUTGOINGS=${OUTGOINGS:-"tun0"}
BAND=${BAND:-"bg"}

# Hotspot subnet (nmcli usually defaults to 10.42.0.0/24)
HOTSPOT_SUBNET=${HOTSPOT_SUBNET:-"10.42.0.0/24"}

VPN_USER=${VPN_USER:-"vpnuser"}
VPN_PASS=${VPN_PASS:-"vpnpass"}
VPN_CONFIG=${VPN_CONFIG:-"default"}
VPN_PATH=${VPN_PATH:-"/etc/openvpn/configs"}


# Enable IP Forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward


# iptables for NAT
# Masquerade only hotspot subnet → tun0
iptables -t nat -A POSTROUTING -s $HOTSPOT_SUBNET -o $OUTGOINGS -j MASQUERADE

# Allow hotspot traffic out/in via tun0
iptables -I DOCKER-USER -s $HOTSPOT_SUBNET -o $OUTGOINGS -j ACCEPT
iptables -I DOCKER-USER -d $HOTSPOT_SUBNET -m state --state RELATED,ESTABLISHED -j ACCEPT


# OpenVPN Setup
VPN_FILE=$(find $VPN_PATH -type f -name "*${VPN_CONFIG}*.ovpn" | head -n 1)

if [ -z "$VPN_FILE" ]; then
  echo "VPN configuration file not found for query: $VPN_CONFIG"
  exit 1
fi

# Write VPN credentials
mkdir -p /etc/openvpn
echo "$VPN_USER" > /etc/openvpn/auth.conf
echo "$VPN_PASS" >> /etc/openvpn/auth.conf
chmod 600 /etc/openvpn/auth.conf

echo "Connecting to VPN..."
openvpn --config ${VPN_FILE} \
  --auth-nocache \
  --auth-user-pass /etc/openvpn/auth.conf \
  --route-nopull &

# Give VPN time to establish
sleep 15


# Policy Routing for Hotspot
# Use numeric table 100 for VPN policy routing
ip rule add from $HOTSPOT_SUBNET table 100 priority 100
ip route add default dev $OUTGOINGS table 100

echo "Policy routing applied: Hotspot ($HOTSPOT_SUBNET) → VPN ($OUTGOINGS)"


# Hotspot Setup
echo "Setting up WiFi hotspot using NMCLI..."
nmcli device wifi hotspot con-name HOTSPOT band $BAND ifname $INTERFACE ssid $AP_SSID password $WPA2_PASS

echo "WiFi hotspot created with SSID: $AP_SSID on $INTERFACE"


# Keep Container Alive
tail -f /dev/null &

# Cleanup on stop
function cleanup {
    echo "Stopping the hotspot..."
    nmcli connection down HOTSPOT
    nmcli connection delete HOTSPOT
    echo "Hotspot stopped."

    # Cleanup ip rules
    ip rule del from $HOTSPOT_SUBNET table vpn
    ip route flush table vpn
}
trap 'cleanup' SIGTERM

wait $!
