FROM debian:latest

RUN apt update && apt upgrade -y
RUN apt install --no-install-recommends -y network-manager iproute2 iptables openvpn dnsmasq

COPY --chmod=755 configuration.sh /bin/configuration.sh

ENTRYPOINT [ "/bin/configuration.sh" ]
