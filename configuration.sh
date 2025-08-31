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

# Start dnsmasq for hotspot
cat > /etc/dnsmasq-hotspot.conf <<EOF
interface=$INTERFACE
dhcp-range=10.42.0.10,10.42.0.250,255.255.255.0,12h
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8
bind-interfaces
EOF
chmod 644 /etc/dnsmasq-hotspot.conf

dnsmasq --conf-file=/etc/dnsmasq-hotspot.conf

# iptables for NAT
iptables -t nat -A POSTROUTING -s $HOTSPOT_SUBNET -o $OUTGOINGS -j MASQUERADE
iptables -A FORWARD -s $HOTSPOT_SUBNET -o $OUTGOINGS -j ACCEPT
iptables -A FORWARD -d $HOTSPOT_SUBNET -m state --state RELATED,ESTABLISHED -j ACCEPT


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
sleep 15



# Policy Routing: only hotspot subnet → VPN
ip rule add from $HOTSPOT_SUBNET table 100 priority 100
ip route add default dev $OUTGOINGS table 100


# Start Hotspot
echo "Setting up WiFi hotspot using NMCLI..."
nmcli device wifi hotspot con-name HOTSPOT band $BAND ifname $INTERFACE ssid $AP_SSID password $WPA2_PASS
echo "WiFi hotspot created with SSID: $AP_SSID on interface $INTERFACE"



# Keep Alive
tail -f /dev/null &

function cleanup {
    echo "Stopping the hotspot..."
    nmcli connection down HOTSPOT
    nmcli connection delete HOTSPOT
    
    ip rule del from $HOTSPOT_SUBNET table 100
    ip route flush table 100

    pkill dnsmasq 2>/dev/null || true
    
    echo "Hotspot stopped."
}
trap 'cleanup' SIGTERM

wait $!
