#!/bin/bash
set -euo pipefail

# Environment Variables for WIFI Hotspot
AP_SSID=${AP_SSID:-"VPN-HOTSPOT"}
WPA2_PASS=${WPA2_PASS:-"password"}
INTERFACE=${INTERFACE:-"wlan0"}
OUTGOINGS=${OUTGOINGS:-"tun0"}
BAND=${BAND:-"bg"}

HOTSPOT_SUBNET=${HOTSPOT_SUBNET:-"10.42.0.0/24"}
HOTSPOT_IP=${HOTSPOT_IP:-"10.42.0.1"}   # gateway for hotspot clients (kept explicit)

# Environment Variables for VPN
VPN_USER=${VPN_USER:-"vpnuser"}
VPN_PASS=${VPN_PASS:-"vpnpass"}
VPN_CONFIG=${VPN_CONFIG:-"default"}
VPN_PATH=${VPN_PATH:-"/etc/openvpn/configs"}

# Helper functions
log() { echo "[$(date +'%H:%M:%S')] $*"; }
safe_kill() { kill "$@" 2>/dev/null || true; }
iptables_del() { iptables -D "$@" 2>/dev/null || true; }
iptables_add() {
  # add only if not present
  if ! iptables -C "$@" 2>/dev/null; then
    iptables -A "$@"
  fi
}

# Privilege check
if [ ! -w "/sys" ] ; then
  echo "[Error] Not running in privileged mode."
  exit 1
fi

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Find VPN file (first match)
VPN_FILE="$(find "${VPN_PATH}" -type f -name "*${VPN_CONFIG}*.ovpn" 2>/dev/null | head -n1 || true)"
if [ -z "${VPN_FILE}" ]; then
  log "VPN configuration file not found for query: ${VPN_CONFIG}. Continuing without VPN..."
  VPN_ENABLED=0
else
  log "Found VPN config: ${VPN_FILE}"
  VPN_ENABLED=1
fi

# Start VPN (if found) and wait for tun device
if [ "${VPN_ENABLED}" -eq 1 ]; then
  mkdir -p /etc/openvpn
  printf "%s\n%s\n" "${VPN_USER}" "${VPN_PASS}" > /etc/openvpn/auth.conf
  chmod 600 /etc/openvpn/auth.conf

  log "Starting OpenVPN (background)..."
  openvpn --config "${VPN_FILE}" \
    --auth-nocache \
    --auth-user-pass /etc/openvpn/auth.conf \
    --route-nopull &
  VPN_PID=$!

  # Wait for OUTGOINGS (tun device) to appear (timeout)
  WAIT=0
  TIMEOUT=40
  while ! ip link show "${OUTGOINGS}" >/dev/null 2>&1; do
    sleep 1
    WAIT=$((WAIT+1))
    if [ "$WAIT" -ge "$TIMEOUT" ]; then
      log "Warning: VPN interface ${OUTGOINGS} did not appear after ${TIMEOUT}s"
      break
    fi
  done
fi

# Determine outgoing interface to NAT through
if [ "${VPN_ENABLED}" -eq 1 ] && ip link show "${OUTGOINGS}" >/dev/null 2>&1; then
  OUT_CONN="${OUTGOINGS}"
else
  # find default egress
  OUT_CONN="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [ -z "${OUT_CONN}" ]; then
    log "Could not detect default egress interface; using 'eth0' as fallback"
    OUT_CONN="eth0"
  fi
fi
log "Using egress: ${OUT_CONN}"

# Idempotent iptables: remove any existing equivalent rules then add
log "Applying iptables rules (hotspot:${HOTSPOT_SUBNET} -> ${OUT_CONN})"
# NAT
iptables_del -t nat POSTROUTING -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j MASQUERADE
iptables_add -t nat POSTROUTING -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j MASQUERADE

# Forwarding
iptables_del FORWARD -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j ACCEPT
iptables_add FORWARD -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j ACCEPT

iptables_del FORWARD -d "${HOTSPOT_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables_add FORWARD -d "${HOTSPOT_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT

# If VPN is enabled and tun exists, add policy routing table 100 for hotspot -> VPN
if [ "${VPN_ENABLED}" -eq 1 ] && ip link show "${OUTGOINGS}" >/dev/null 2>&1; then
  log "Configuring policy routing: ${HOTSPOT_SUBNET} -> table 100 via ${OUT_CONN}"
  ip rule del from "${HOTSPOT_SUBNET}" table 100 2>/dev/null || true
  ip route flush table 100 2>/dev/null || true
  ip rule add from "${HOTSPOT_SUBNET}" table 100 priority 100
  ip route add default dev "${OUT_CONN}" table 100
fi

# Prepare Wi-Fi interface / AP mode
log "Setting up interface ${INTERFACE} as AP"
ip link set "${INTERFACE}" down 2>/dev/null || true
# attempt to set AP mode (may fail on some drivers)
iw dev "${INTERFACE}" set type __ap >/dev/null 2>&1 || true
ip addr flush dev "${INTERFACE}" || true
ip addr add "${HOTSPOT_IP}/24" dev "${INTERFACE}"
ip link set "${INTERFACE}" up

# Decide hostapd hw_mode based on BAND env (if 'a' then 5GHz, else g)
if [ "${BAND}" = "a" ]; then
  HW_MODE="a"
  CHANNEL=${CHANNEL:-36}
else
  HW_MODE="g"
  CHANNEL=${CHANNEL:-6}
fi

# Create hostapd config
mkdir -p /etc/hostapd
cat > /etc/hostapd/hotspot.conf <<EOF
interface=${INTERFACE}
driver=nl80211
ssid=${AP_SSID}
hw_mode=${HW_MODE}
channel=${CHANNEL}
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${WPA2_PASS}
max_num_sta=32
EOF

# Start hostapd
log "Starting hostapd (SSID=${AP_SSID}, hw_mode=${HW_MODE}, channel=${CHANNEL})"
hostapd /etc/hostapd/hotspot.conf &
HOSTAPD_PID=$!

sleep 2

# Configure dnsmasq standalone (not NetworkManager path)
DNSMASQ_CONF="/etc/dnsmasq.hotspot.conf"
DHCP_START="${HOTSPOT_IP%.*}.10"
DHCP_END="${HOTSPOT_IP%.*}.100"
cat > "${DNSMASQ_CONF}" <<EOF
interface=${INTERFACE}
bind-interfaces
no-resolv
server=1.1.1.1
server=8.8.8.8
domain-needed
bogus-priv
dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h
dhcp-option=3,${HOTSPOT_IP}
dhcp-option=6,1.1.1.1,8.8.8.8
log-dhcp
EOF

# Kill any old dnsmasq using same conf and start a new one
pkill -f "dnsmasq --conf-file=${DNSMASQ_CONF}" 2>/dev/null || true
dnsmasq --conf-file="${DNSMASQ_CONF}" --pid-file=/run/dnsmasq.hotspot.pid &
DNSMASQ_PID=$!

log "Hotspot started: SSID='${AP_SSID}' on ${INTERFACE}, clients will be in ${HOTSPOT_SUBNET} and egress via ${OUT_CONN}"

# Cleanup function
cleanup() {
  log "Stopping hotspot and cleaning up..."

  safe_kill "${HOSTAPD_PID:-}" || true
  safe_kill "${DNSMASQ_PID:-}" || true
  if [ "${VPN_ENABLED:-0}" -eq 1 ]; then
    safe_kill "${VPN_PID:-}" || true
    ip rule del from "${HOTSPOT_SUBNET}" table 100 2>/dev/null || true
    ip route flush table 100 2>/dev/null || true
  fi

  # remove iptables rules we added
  iptables_del -t nat POSTROUTING -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j MASQUERADE
  iptables_del FORWARD -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j ACCEPT
  iptables_del FORWARD -d "${HOTSPOT_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT

  log "Cleanup finished."
}

trap cleanup SIGINT SIGTERM EXIT

# keep running
tail -f /dev/null & wait $!
