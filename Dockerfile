FROM debian:bookworm-slim

RUN apt update && apt upgrade -y
RUN apt install --no-install-recommends -y iproute2 iptables openvpn dnsmasq hostapd network-manager

COPY --chmod=755 configuration.sh /bin/configuration.sh

ENTRYPOINT [ "/bin/configuration.sh" ]
