#!/bin/bash -Eeuo pipefail

# ===== Privilege & safety checks =====
if [[ ! -w /proc/sys/net/ipv4/ip_forward ]]; then
  echo "[Error] Not running in privileged mode (need NET_ADMIN & access to /proc/sys)." >&2
  exit 1
fi

# ===== Defaults (env override) =====
AP_SSID="${AP_SSID:-VPN-HOTSPOT}"
WPA2_PASS="${WPA2_PASS:-password}"
INTERFACE="${INTERFACE:-wlan0}"

# Hotspot addressing
HOTSPOT_SUBNET="${HOTSPOT_SUBNET:-10.42.0.0/24}"
HOTSPOT_IP="${HOTSPOT_IP:-10.42.0.1}"
DHCP_START="${DHCP_START:-10.42.0.100}"
DHCP_END="${DHCP_END:-10.42.0.200}"

# Radio band/channel
BAND="${BAND:-g}"               # g = 2.4GHz, a = 5GHz
CHANNEL="${CHANNEL:-}"          # optional; auto-set below if empty
DRIVER="${DRIVER:-nl80211}"
COUNTRY="${COUNTRY:-}"          # e.g. RO/US/DE ; leave empty to omit

# Outgoing interface when VPN is enabled (usually tun0)
OUTGOINGS="${OUTGOINGS:-tun0}"

# VPN settings
VPN_USER="${VPN_USER:-vpnuser}"
VPN_PASS="${VPN_PASS:-vpnpass}"
VPN_CONFIG="${VPN_CONFIG:-default}"
VPN_PATH="${VPN_PATH:-/etc/openvpn/configs}"

# dnsmasq settings
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"

# ===== Helpers =====
log() { echo "[$(date +'%H:%M:%S')] $*"; }

iptables_add() { # idempotent add
  if ! iptables -C "$@" 2>/dev/null; then
    iptables -A "$@"
  fi
}
iptables_del() { # best-effort delete
  iptables -D "$@" 2>/dev/null || true
}

wait_for_if() {
  local ifname="$1" timeout="${2:-30}" sec=0
  while ! ip link show "$ifname" >/dev/null 2>&1; do
    (( sec++ >= timeout )) && { echo "[Error] Interface $ifname not present after ${timeout}s." >&2; return 1; }
    sleep 1
  done
}

# Extract CIDR /24 mask from HOTSPOT_SUBNET
HOTSPOT_NET="${HOTSPOT_SUBNET%/*}"
HOTSPOT_CIDR="${HOTSPOT_SUBNET#*/}"

# ===== Enable forwarding & dynamic addr =====
for k in ip_dynaddr ip_forward; do
  if [[ "$(cat /proc/sys/net/ipv4/$k)" != "1" ]]; then
    echo 1 > "/proc/sys/net/ipv4/$k"
  fi
done

# ===== Discover VPN file (if any) =====
VPN_FILE="$(find "$VPN_PATH" -type f -name "*${VPN_CONFIG}*.ovpn" | head -n1 || true)"
VPN_ENABLED=0
if [[ -n "${VPN_FILE:-}" ]]; then
  VPN_ENABLED=1
  log "Using VPN config: $VPN_FILE"
else
  log "No VPN config found for query: $VPN_CONFIG — continuing without VPN."
fi

# ===== Bring up Wi-Fi interface cleanly =====
rfkill unblock wlan || true

log "Configuring Wi-Fi interface ${INTERFACE}"
ip link set "$INTERFACE" down || true
iw dev "$INTERFACE" set type __ap || true
ip addr flush dev "$INTERFACE" || true
ip addr add "${HOTSPOT_IP}/24" dev "$INTERFACE"
ip link set "$INTERFACE" up

# ===== hostapd config =====
mkdir -p /etc/hostapd
HOSTAPD_CONF="/etc/hostapd/hotspot.conf"

# Decide band/channel defaults
if [[ "$BAND" == "a" ]]; then
  : "${CHANNEL:=36}"   # common 5GHz non-DFS default (adjust per-country if needed)
  HW_MODE="a"
  HT_LINES=$'ieee80211n=1\nieee80211ac=1\nwmm_enabled=1'
else
  : "${CHANNEL:=6}"
  HW_MODE="g"
  HT_LINES=$'ieee80211n=1\nwmm_enabled=1'
fi

{
  echo "interface=${INTERFACE}"
  echo "driver=${DRIVER}"
  [[ -n "$COUNTRY" ]] && echo "country_code=${COUNTRY}"
  echo "ssid=${AP_SSID}"
  echo "hw_mode=${HW_MODE}"
  echo "channel=${CHANNEL}"
  echo "$HT_LINES"
  echo "auth_algs=1"
  echo "ignore_broadcast_ssid=0"
  echo "wpa=2"
  echo "wpa_key_mgmt=WPA-PSK"
  echo "rsn_pairwise=CCMP"
  echo "wpa_passphrase=${WPA2_PASS}"
  echo "max_num_sta=32"
} > "$HOSTAPD_CONF"

# ===== Start hostapd =====
log "Starting hostapd (SSID: ${AP_SSID}, band: ${BAND}, channel: ${CHANNEL})"
hostapd "$HOSTAPD_CONF" &
HOSTAPD_PID=$!

# ===== Start OpenVPN (optional) and wait for tun =====
if (( VPN_ENABLED )); then
  mkdir -p /etc/openvpn
  printf "%s\n%s\n" "$VPN_USER" "$VPN_PASS" > /etc/openvpn/auth.conf
  chmod 600 /etc/openvpn/auth.conf

  log "Starting OpenVPN…"
  openvpn --config "$VPN_FILE" \
          --auth-nocache \
          --auth-user-pass /etc/openvpn/auth.conf \
          --route-nopull \
          --daemon \
          --writepid /var/run/openvpn-hotspot.pid

  # Wait for tun to appear
  wait_for_if "$OUTGOINGS" 40
  VPN_PID="$(cat /var/run/openvpn-hotspot.pid 2>/dev/null || true)"
  OUT_CONN="$OUTGOINGS"
else
  # No VPN: autodetect default egress
  OUT_CONN="$(ip route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  log "No VPN; using default egress interface: ${OUT_CONN}"
fi

# ===== Policy routing: only hotspot subnet -> VPN (if VPN) =====
if (( VPN_ENABLED )); then
  log "Setting policy routing for ${HOTSPOT_SUBNET} via ${OUT_CONN}"
  # Clear table 100 then add fresh default via OUT_CONN
  ip route flush table 100 || true
  ip rule del from "${HOTSPOT_SUBNET}" table 100 2>/dev/null || true
  ip rule add from "${HOTSPOT_SUBNET}" table 100 priority 100
  ip route add default dev "${OUT_CONN}" table 100
fi

# ===== NAT & FORWARD rules (idempotent) =====
log "Applying iptables rules (egress: ${OUT_CONN})"
# NAT masquerade for hotspot subnet out the chosen egress
iptables_del -t nat POSTROUTING -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j MASQUERADE
iptables_add -t nat POSTROUTING -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j MASQUERADE

# Forwarding rules
iptables_del FORWARD -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j ACCEPT
iptables_add FORWARD -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j ACCEPT

iptables_del FORWARD -d "${HOTSPOT_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables_add FORWARD -d "${HOTSPOT_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT

# ===== dnsmasq: standalone DNS + DHCP (authoritative) =====
log "Starting dnsmasq (DNS: ${DNS1}, ${DNS2}; DHCP ${DHCP_START}-${DHCP_END})"
mkdir -p /run/dnsmasq
DNSMASQ_CONF="/etc/dnsmasq.hotspot.conf"
cat > "$DNSMASQ_CONF" <<EOF
interface=${INTERFACE}
bind-interfaces
except-interface=lo
domain-needed
bogus-priv
no-resolv
server=${DNS1}
server=${DNS2}
dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h
dhcp-option=3,${HOTSPOT_IP}          # router
dhcp-option=6,${DNS1},${DNS2}        # DNS
log-dhcp
EOF

# Kill any previous dnsmasq instance that may conflict
pkill -f "dnsmasq --conf-file=${DNSMASQ_CONF}" 2>/dev/null || true
dnsmasq --conf-file="${DNSMASQ_CONF}" --pid-file=/run/dnsmasq/hotspot.pid
DNSMASQ_PID="$(cat /run/dnsmasq/hotspot.pid 2>/dev/null || true)"

log "Hotspot up. SSID='${AP_SSID}' on ${INTERFACE}; clients will egress via ${OUT_CONN} $( ((VPN_ENABLED)) && echo '(VPN)')"

# ===== Cleanup on exit =====
cleanup() {
  log "Cleaning up…"

  # dnsmasq
  if [[ -n "${DNSMASQ_PID:-}" ]]; then
    kill "${DNSMASQ_PID}" 2>/dev/null || true
  else
    pkill -f "dnsmasq --conf-file=${DNSMASQ_CONF}" 2>/dev/null || true
  fi

  # hostapd
  if [[ -n "${HOSTAPD_PID:-}" ]]; then
    kill "${HOSTAPD_PID}" 2>/dev/null || true
  fi

  # OpenVPN & policy routing
  if (( VPN_ENABLED )); then
    if [[ -n "${VPN_PID:-}" ]]; then
      kill "${VPN_PID}" 2>/dev/null || true
    else
      pkill -f "openvpn --config ${VPN_FILE}" 2>/dev/null || true
    fi
    ip rule del from "${HOTSPOT_SUBNET}" table 100 2>/dev/null || true
    ip route flush table 100 2>/dev/null || true
  fi

  # iptables
  iptables_del -t nat POSTROUTING -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j MASQUERADE
  iptables_del FORWARD -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j ACCEPT
  iptables_del FORWARD -d "${HOTSPOT_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT

  log "Cleanup done."
}
trap cleanup INT TERM EXIT

# Keep process in foreground so traps work
tail -f /dev/null
