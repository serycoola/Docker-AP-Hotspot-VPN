#!/bin/bash
set -euo pipefail

# ------------------------
# VPN Hotspot (improved)
# ------------------------
AP_SSID=${AP_SSID:-"VPN-HOTSPOT"}
WPA2_PASS=${WPA2_PASS:-"password"}
INTERFACE=${INTERFACE:-"wlan0"}
OUTGOINGS=${OUTGOINGS:-"tun0"}         # expected VPN tunnel device
BAND=${BAND:-"bg"}

HOTSPOT_SUBNET=${HOTSPOT_SUBNET:-"10.42.0.0/24"}
HOTSPOT_IP=${HOTSPOT_IP:-"10.42.0.1"}

VPN_USER=${VPN_USER:-"vpnuser"}
VPN_PASS=${VPN_PASS:-"vpnpass"}
VPN_CONFIG=${VPN_CONFIG:-"default"}
VPN_PATH=${VPN_PATH:-"/etc/openvpn/configs"}

# helper logging
log() { echo "[$(date +'%H:%M:%S')] $*"; }
safe_kill() { [ -n "${1:-}" ] && kill "$@" 2>/dev/null || true; }

iptables_del() { iptables -D "$@" 2>/dev/null || true; }
iptables_add() {
  # add only if not present
  if ! iptables -C "$@" 2>/dev/null; then
    iptables -A "$@"
  fi
}

# require privileged container (we need /sys and network namespace)
if [ ! -w "/sys" ] ; then
  echo "[Error] Not running in privileged mode. Container needs --privileged or NET_ADMIN capability."
  exit 1
fi

# enable forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# find vpn file
VPN_FILE="$(find "${VPN_PATH}" -type f -name "*${VPN_CONFIG}*.ovpn" 2>/dev/null | head -n1 || true)"
if [ -z "${VPN_FILE}" ]; then
  log "VPN configuration file not found for query: ${VPN_CONFIG}. Continuing without VPN..."
  VPN_ENABLED=0
else
  log "Found VPN config: ${VPN_FILE}"
  VPN_ENABLED=1
fi

# determine egress helper (fallback later if tun not present)
detect_egress() {
  OUT_CONN=""
  if [ "${VPN_ENABLED}" -eq 1 ] && ip link show "${OUTGOINGS}" >/dev/null 2>&1; then
    OUT_CONN="${OUTGOINGS}"
  else
    OUT_CONN="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    OUT_CONN=${OUT_CONN:-"eth0"}
  fi
  echo "${OUT_CONN}"
}

# start vpn (background) with protections so it doesn't change our routing/DNS
start_vpn() {
  if [ "${VPN_ENABLED}" -ne 1 ]; then return; fi
  mkdir -p /etc/openvpn
  printf "%s\n%s\n" "${VPN_USER}" "${VPN_PASS}" > /etc/openvpn/auth.conf
  chmod 600 /etc/openvpn/auth.conf

  log "Starting OpenVPN (background) with pull-filter ignores..."
  # ignore server pushed redirect-gateway and dhcp-option (DNS)
  # route-noexec prevents openvpn from installing routes itself
  openvpn --config "${VPN_FILE}" \
    --auth-nocache \
    --auth-user-pass /etc/openvpn/auth.conf \
    --route-nopull \
    --route-noexec \
    --pull-filter ignore "redirect-gateway" \
    --pull-filter ignore "dhcp-option" \
    --verb 3 &
  VPN_PID=$!
  log "OpenVPN pid=${VPN_PID}"
}

# start hostapd
start_hostapd() {
  HW_MODE="g"; CHANNEL=${CHANNEL:-6}
  if [ "${BAND}" = "a" ]; then HW_MODE="a"; CHANNEL=${CHANNEL:-36}; fi

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
ctrl_interface=/var/run/hostapd
beacon_int=100
disassoc_low_ack=0
EOF

  log "Starting hostapd (SSID=${AP_SSID}, hw_mode=${HW_MODE}, channel=${CHANNEL})"
  hostapd /etc/hostapd/hotspot.conf &
  HOSTAPD_PID=$!
}

# start dnsmasq confined to the interface
start_dnsmasq() {
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

  # ensure previous pid/killed
  pkill -f "dnsmasq --conf-file=${DNSMASQ_CONF}" 2>/dev/null || true
  # start in background, bind explicitly (safer)
  dnsmasq --conf-file="${DNSMASQ_CONF}" --interface="${INTERFACE}" --bind-interfaces --keep-in-foreground &
  DNSMASQ_PID=$!
  log "dnsmasq pid=${DNSMASQ_PID}"
}

# configure interface and hostapd prerequisites
prepare_interface() {
  log "Preparing ${INTERFACE} as AP and assigning ${HOTSPOT_IP}"
  ip link set "${INTERFACE}" down 2>/dev/null || true
  iw dev "${INTERFACE}" set type __ap >/dev/null 2>&1 || true || true
  ip addr flush dev "${INTERFACE}" || true
  ip addr add "${HOTSPOT_IP}/24" dev "${INTERFACE}" || true
  ip link set "${INTERFACE}" up
}

# apply iptables idempotently
apply_iptables() {
  OUT_CONN="$1"
  log "Applying iptables rules (hotspot:${HOTSPOT_SUBNET} -> ${OUT_CONN})"
  # NAT
  iptables_del -t nat POSTROUTING -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j MASQUERADE
  iptables_add -t nat POSTROUTING -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j MASQUERADE

  # Forwarding
  iptables_del FORWARD -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j ACCEPT
  iptables_add FORWARD -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j ACCEPT

  iptables_del FORWARD -d "${HOTSPOT_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables_add FORWARD -d "${HOTSPOT_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

# policy routing table 100: route hotspot traffic via chosen egress
apply_policy_routing() {
  OUT_CONN="$1"
  # remove any old rule for safety, then add
  ip rule del from "${HOTSPOT_SUBNET}" table 100 2>/dev/null || true
  ip route flush table 100 2>/dev/null || true
  ip rule add from "${HOTSPOT_SUBNET}" table 100 priority 100
  # use dev route if OUT_CONN is a device (tun0) otherwise try to use gateway
  # If OUT_CONN is a regular interface we add default dev; if not, fallback on main table
  if ip link show "${OUT_CONN}" >/dev/null 2>&1; then
    ip route add default dev "${OUT_CONN}" table 100
  else
    # attempt to pick default gateway via OUT_CONN from main table
    gw=$(ip route show default 0.0.0.0/0 dev "${OUT_CONN}" 2>/dev/null | awk '/via/ {print $3; exit}' || true)
    if [ -n "${gw}" ]; then
      ip route add default via "${gw}" dev "${OUT_CONN}" table 100
    else
      ip route add default dev "${OUT_CONN}" table 100 || true
    fi
  fi
  log "Policy routing set: ${HOTSPOT_SUBNET} -> table 100 via ${OUT_CONN}"
}

# cleanup
cleanup() {
  log "Stopping hotspot and cleaning up..."
  safe_kill "${HOSTAPD_PID:-}" || true
  safe_kill "${DNSMASQ_PID:-}" || true
  safe_kill "${VPN_PID:-}" || true

  ip rule del from "${HOTSPOT_SUBNET}" table 100 2>/dev/null || true
  ip route flush table 100 2>/dev/null || true

  OUT_CONN="$(detect_egress)"
  iptables_del -t nat POSTROUTING -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j MASQUERADE || true
  iptables_del FORWARD -s "${HOTSPOT_SUBNET}" -o "${OUT_CONN}" -j ACCEPT || true
  iptables_del FORWARD -d "${HOTSPOT_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT || true

  log "Cleanup finished."
}

trap cleanup SIGINT SIGTERM EXIT

# ------------------------
# Start sequence
# ------------------------
start_vpn

# wait briefly for VPN device, but don't block forever
if [ "${VPN_ENABLED}" -eq 1 ]; then
  WAIT=0; TIMEOUT=30
  while ! ip link show "${OUTGOINGS}" >/dev/null 2>&1; do
    sleep 1; WAIT=$((WAIT+1))
    if [ "$WAIT" -ge "$TIMEOUT" ]; then
      log "Warning: VPN interface ${OUTGOINGS} did not appear after ${TIMEOUT}s - continuing with fallback egress"
      break
    fi
  done
fi

# choose egress and apply iptables + policy routing
EGRESS="$(detect_egress)"
apply_iptables "${EGRESS}"
if [ "${VPN_ENABLED}" -eq 1 ] && ip link show "${OUTGOINGS}" >/dev/null 2>&1; then
  apply_policy_routing "${OUTGOINGS}"
else
  apply_policy_routing "${EGRESS}"
fi

# prepare interface and start wifi services
prepare_interface
start_hostapd
sleep 1
start_dnsmasq

log "Hotspot started: SSID='${AP_SSID}' on ${INTERFACE}, gateway ${HOTSPOT_IP}, egress ${EGRESS}"

# ------------------------
# Watchdog / self-healing
# ------------------------
watchdog() {
  # runs forever, every 15 seconds: check processes and routing rules, attempt to heal
  while true; do
    sleep 15

    # re-evaluate egress (tun might appear later)
    NEW_EGRESS="$(detect_egress)"
    if [ "${NEW_EGRESS}" != "${EGRESS}" ]; then
      log "[watchdog] Egress changed: ${EGRESS} -> ${NEW_EGRESS}"
      EGRESS="${NEW_EGRESS}"
      apply_iptables "${EGRESS}"
      if [ "${VPN_ENABLED}" -eq 1 ] && ip link show "${OUTGOINGS}" >/dev/null 2>&1; then
        apply_policy_routing "${OUTGOINGS}"
      else
        apply_policy_routing "${EGRESS}"
      fi
    fi

    # ensure ip rule still present
    if ! ip rule show | grep -q "${HOTSPOT_SUBNET}"; then
      log "[watchdog] ip rule missing, reapplying"
      if [ "${VPN_ENABLED}" -eq 1 ] && ip link show "${OUTGOINGS}" >/dev/null 2>&1; then
        apply_policy_routing "${OUTGOINGS}"
      else
        apply_policy_routing "${EGRESS}"
      fi
    fi

    # restart hostapd if dead
    if ! pgrep -x hostapd >/dev/null 2>&1; then
      log "[watchdog] hostapd not running, restarting..."
      start_hostapd
    fi

    # restart dnsmasq if dead
    if ! pgrep -x dnsmasq >/dev/null 2>&1; then
      log "[watchdog] dnsmasq not running, restarting..."
      start_dnsmasq
    fi

    # if vpn enabled but openvpn died -> restart
    if [ "${VPN_ENABLED}" -eq 1 ]; then
      if ! pgrep -x openvpn >/dev/null 2>&1; then
        log "[watchdog] openvpn not running, restarting..."
        start_vpn
      fi
      # ensure tun exists when vpn expected
      if ! ip link show "${OUTGOINGS}" >/dev/null 2>&1; then
        log "[watchdog] ${OUTGOINGS} not present yet"
      fi
    fi

    # quick status log (minimal)
    log "[status] hostapd=$(pgrep -x hostapd || echo dead) dnsmasq=$(pgrep -x dnsmasq || echo dead) openvpn=$(pgrep -x openvpn || echo dead) tun=$(ip link show ${OUTGOINGS} >/dev/null 2>&1 && echo up || echo down)"
  done
}

watchdog &

# keep container alive until signal arrives
wait
