FROM debian:latest

RUN apt update && apt upgrade -y
RUN apt install --no-install-recommends -y network-manager iproute2 iptables openvpn

ADD configuration.sh /bin/configuration.sh

ENTRYPOINT [ "/bin/configuration.sh" ]
