FROM debian:latest

RUN apt update && apt upgrade -y
RUN apt install --no-install-recommends -y iproute2 iptables openvpn dnsmasq hostapd #network-manager

COPY --chmod=755 hostapd_script.sh /bin/hostapd_script.sh

ENTRYPOINT [ "/bin/hostapd_script.sh" ]
