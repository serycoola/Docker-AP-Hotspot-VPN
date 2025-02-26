FROM debian:latest

RUN apt update && apt upgrade -y
RUN apt install --no-install-recommends -y network-manager iproute2 iptables openvpn

ADD nmcli_configuration.sh /bin/nmcli_configuration.sh

CMD [ "/bin/nmcli_configuration.sh" ]
