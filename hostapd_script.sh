#!/bin/bash -e

# ==============================
# Environment Variables for WIFI Hotspot
# ==============================
AP_SSID=${AP_SSID:-"VPN-HOTSPOT"}
WPA2_PASS=${WPA2_PASS:-"password"}
INTERFACE=${INTERFACE:-"wlan0"}
OUTGOINGS=${OUTGOINGS:-"tun0"}   # default to VPN tunnel
BAND=${BAND:-"bg"}
HOTSPOT_SUBNET=${HOTSPOT_SUBNET:-"10.42.0.0/24"}
HOTSPOT_ADDR=${HOTSPOT_ADDR:-"10.42.0.1"}

# ==============================
# Environment Variables for VPN
# ==============================
VPN_USER=${VPN_USER:-"vpnuser"}
VPN_PASS=${VPN_PASS:-"vpnpass"}
VPN_CONFIG=${VPN_CONFIG:-"default.ovpn"}
VPN_PATH=${VPN_PATH:-"/etc/openvpn/configs"}

# ==============================
# Privileged mode check
# ==============================
if [ ! -w "/sys" ] ; then
    echo "[Error] Not running in privileged mode."
    exit 1
fi

# ==============================
# Generate hostapd config
# ==============================
cat > "/etc/hostapd.conf" <<EOF
interface=${INTERFACE}
driver=nl80211
ssid=${AP_SSID}
hw_mode=${BAND}
channel=6
wpa=2
wpa_passphrase=${WPA2_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wmm_enabled=1
EOF

# ==============================
# Start VPN (if config exists)
# ==============================
if [ -f "${VPN_PATH}/${VPN_CONFIG}" ]; then
    echo "[INFO] Starting OpenVPN with config ${VPN_CONFIG}..."
    echo -e "${VPN_USER}\n${VPN_PASS}" > /tmp/vpn-auth.txt
    chmod 600 /tmp/vpn-auth.txt
    openvpn --config "${VPN_PATH}/${VPN_CONFIG}" --auth-user-pass /tmp/vpn-auth.txt --daemon
    sleep 5
fi

# ==============================
# Network setup
# ==============================
rfkill unblock wlan
ip link set ${INTERFACE} up
ip addr flush dev ${INTERFACE}
ip addr add ${HOTSPOT_ADDR}/24 dev ${INTERFACE}

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# ==============================
# Configure iptables NAT
# ==============================
iptables -t nat -D POSTROUTING -s ${HOTSPOT_SUBNET} -o ${OUTGOINGS} -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s ${HOTSPOT_SUBNET} -o ${OUTGOINGS} -j MASQUERADE

iptables -D FORWARD -i ${INTERFACE} -o ${OUTGOINGS} -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i ${INTERFACE} -o ${OUTGOINGS} -j ACCEPT

iptables -D FORWARD -i ${OUTGOINGS} -o ${INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i ${OUTGOINGS} -o ${INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT

# ==============================
# Configure dnsmasq for DHCP + DNS
# ==============================
cat > "/etc/dnsmasq.conf" <<EOF
interface=${INTERFACE}
dhcp-range=${HOTSPOT_ADDR%.*}.50,${HOTSPOT_ADDR%.*}.150,12h
dhcp-option=3,${HOTSPOT_ADDR}       # gateway
dhcp-option=6,1.1.1.1,8.8.8.8       # DNS
log-queries
log-dhcp
EOF

echo "[INFO] Starting dnsmasq..."
dnsmasq --no-daemon --conf-file=/etc/dnsmasq.conf &

# ==============================
# Start hotspot
# ==============================
echo "[INFO] Starting HostAPD..."
exec /usr/sbin/hostapd /etc/hostapd.conf
