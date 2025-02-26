# Docker container stack: Access Point + VPN

Simple DOCKER container that creates a WIFI hotspot, by utilising NMCLI (Network
Manager) and broadcasts a VPN connection using OpenVPN. It is built on the base
docker image of Debian, and was developed and tested to run on ZimaOS.



## Prerequisites

This container expects to find .ovpn files inside /etc/openvpn/configs so you
need to make sure to bind a local folder containing your desired config files
to that location [-v /folder/containing/ovpn/files:/etc/openvpn/configs].

Alternatively, if you wish to bind your local folder in a different location
inside the docker image, you can use the environment variable VPN_PATH to
specify your custom location [-v /folder/containing/ovpn/files:/custom/folder
-e VPN_PATH=/custom/folder].

In case no configuration files are provided, or VPN_CONFIG finds no file in
the VPN_PATH folder that mathces your search query, OpenVPN will fail the
set up process and the resulting access point will simply forward your regular
network connection, like a normal hotspot.

Like any other hotspot created in linux, this expects two different network
adapters in order to be able to forward the internet from one [eth0, tun0] to
the other [wlan0]. Also, you must make sure your host system already has all
the network drivers preinstalled. If ZimaOS does not support your WiFi card,
this will not install any drivers for it.



## HOTSPOT configuration

In order to set up the hotspot function, you need to first configure the
following environment variables:

* **AP_SSID**: 	your preferred name for your hotspot connection. 
	       	Default is "VPN-HOTSPOT".
* **WPA2_PASS**: the password to be used for your hotspot connection. 
		Default is "password"

* **BAND**: set by default to "bg" (2.4 GhZ). For 5 GhZ use "a".

Since this container uses nmcli to set up the hotspot, you NEED to pass through
the DBUS of the host system [-v /var/run/dbus:/var/run/dbus].


# VPN configuration

In case this is not set up, OpenVPN will fail connecting and the hotspot will
broadcast your regular network connection.

In order to set up the VPN function, you need to configure the following:

* **VPN_USER**: your OpenVPN username. Can be found under account settings,
		for your VPN provider of choice. 
* **VPN_PASS**: your OpenVPN password. Can be found under account settings,
		for your VPN provider of choice.
* **VPN_CONFIG**: partial or full name of the config you want to load, just
              	enough info to filter out a single file in the folder. Works
		like a search query. If more files are found for your search
		query, the first config will be used.

This container is configured to use .ovpn files in order to connect to the VPN,
so you need a VPN provider that allows you to download those. If you are looking
for a free option, ProtonVPN is the one I would highly recommend.



## Experimental features

If in your case the WiFi adapter is not identified in nmcli as wlan0 and your
outbound connection is not identified as tun0, or eth0, you can manually set
them using the following environment variables:

* **INTERFACE**: configures the WiFi adapter to be used. Default is wlan0
* **OUTGOINGS**: configures the outbound connection. Default is tun0.

Alternatively, if you need to change the default mount location of the folder
containing the VPN configs, you need to specify this:

* **VPN_PATH**: sets the folder where OpenVPN will look for .ovpn config files.
		It is set by default to /etc/openvpn/configs



## BUILD, RUN, COMPOSE

This container is not yet uploaded to docker hub. You need to build it first, 
before first time use. Copy all files inside a folder on your machine, navigate
to that folder in the terminal, and run:

* docker build -t docker-ap-vpn .

A Docker Compose file has been provided in the repository. You can import that into
ZimaOS and configure the empty Environment Variables.



## License

Implemented by Serban Ciobanu under MIT License.

