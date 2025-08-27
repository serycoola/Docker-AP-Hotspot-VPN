#!/bin/bash

# Environment Variables for WiFi Hotspot
AP_SSID=${AP_SSID:-"VPN-HOTSPOT"}
WPA2_PASS=${WPA2_PASS:-"password"}
INTERFACE=${INTERFACE:-"wlan0"}
OUTGOINGS=${OUTGOINGS:-"tun0"}
BAND=${BAND:-"bg"}

# Hotspot subnet (nmcli usually defaults to 10.42.0.0/24 for hotspots)
HOTSPOT_SUBNET=${HOTSPOT_SUBNET:-"10.42.0.0/24"}

# Environment Variables for VPN
VPN_USER=${VPN_USER:-"vpnuser"}
VPN_PASS=${VPN_PASS:-"vpnpass"}
VPN_CONFIG=${VPN_CONFIG:-"default"}
VPN_PATH=${VPN_PATH:-"/etc/openvpn/configs"}



# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Use DOCKER-USER chain so we don’t collide with Docker’s own NAT
iptables -t nat -A POSTROUTING -s $HOTSPOT_SUBNET -o $OUTGOINGS -j MASQUERADE

# Allow hotspot subnet forwarding specifically
iptables -I DOCKER-USER -s $HOTSPOT_SUBNET -o $OUTGOINGS -j ACCEPT
iptables -I DOCKER-USER -d $HOTSPOT_SUBNET -m state --state RELATED,ESTABLISHED -j ACCEPT



# Find the first VPN configuration file that matches VPN_CONFIG
VPN_FILE=$(find $VPN_PATH -type f -name "*${VPN_CONFIG}*.ovpn" | head -n 1)

if [ -z "$VPN_FILE" ]; then
  echo "VPN configuration file not found for query: $VPN_CONFIG"
fi

# Write VPN credentials to auth.conf
mkdir -p /etc/openvpn
echo "$VPN_USER" > /etc/openvpn/auth.conf
echo "$VPN_PASS" >> /etc/openvpn/auth.conf
chmod 600 /etc/openvpn/auth.conf

# Configure and connect to VPN
echo "Connecting to VPN..."
openvpn --config ${VPN_FILE} --auth-nocache --auth-user-pass /etc/openvpn/auth.conf --route-nopull --route 10.42.0.0 255.255.255.0 &
sleep 10

echo "WiFi hotspot is now connected to the following VPN config:"
echo "$VPN_FILE"



# Configure and start the WiFi hotspot
echo "Setting up WiFi hotspot using NMCLI..."
nmcli device wifi hotspot con-name HOTSPOT band $BAND ifname $INTERFACE ssid $AP_SSID password $WPA2_PASS

echo "WiFi hotspot created with SSID: $AP_SSID on interface $INTERFACE"



# Keep the container running
tail -f /dev/null &



# Trap SIGTERM and STOP the HOTSPOT
function cleanup {
    echo "Stopping the hotspot..."
    nmcli connection down HOTSPOT
    nmcli connection delete HOTSPOT
    echo "Hotspot stopped."
}

trap 'cleanup' SIGTERM

wait $!
