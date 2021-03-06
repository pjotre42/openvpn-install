#!/bin/bash
#
# https://github.com/Nyr/openvpn-install
#
# Copyright (c) 2013 Nyr. Released under the MIT License.


server_mode="material"
subnet=1
masquerade=1


# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
	echo "This script needs to be run with bash, not sh"
	exit
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "Sorry, you need to run this as root"
	exit
fi

# Detect OS
# $os_version variables aren't always in use, but are kept here for convenience
if grep -qs "ubuntu" /etc/os-release; then
	os="ubuntu"
	os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
	group_name="nogroup"
elif [[ -e /etc/debian_version ]]; then
	os="debian"
	os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
	group_name="nogroup"
elif [[ -e /etc/centos-release ]]; then
	os="centos"
	os_version=$(grep -oE '[0-9]+' /etc/centos-release | head -1)
	group_name="nobody"
elif [[ -e /etc/fedora-release ]]; then
	os="fedora"
	os_version=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
	group_name="nobody"
else
	echo "Looks like you aren't running this installer on Ubuntu, Debian, CentOS or Fedora"
	exit
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 1804 ]]; then
	echo "Ubuntu 18.04 or higher is required to use this installer
This version of Ubuntu is too old and unsupported"
	exit
fi

if [[ "$os" == "debian" && "$os_version" -lt 9 ]]; then
	echo "Debian 9 or higher is required to use this installer
This version of Debian is too old and unsupported"
	exit
fi

if [[ "$os" == "centos" && "$os_version" -lt 7 ]]; then
	echo "CentOS 7 or higher is required to use this installer
This version of CentOS is too old and unsupported"
	exit
fi

if [[ ! -e /dev/net/tun ]]; then
	echo "The TUN device is not available
You need to enable TUN before running this script"
	exit
fi

new_client () {
	# Generates the custom client.ovpn
	{
	cat /etc/openvpn/server/client-"$server_mode"-common.txt
	echo "<ca>"
	cat /etc/openvpn/server/easy-rsa-"$server_mode"/pki/ca.crt
	echo "</ca>"
	echo "<cert>"
	sed -ne '/BEGIN CERTIFICATE/,$ p' /etc/openvpn/server/easy-rsa-"$server_mode"/pki/issued/"$client".crt
	echo "</cert>"
	echo "<key>"
	cat /etc/openvpn/server/easy-rsa-"$server_mode"/pki/private/"$client".key
	echo "</key>"
	echo "<tls-crypt>"
	sed -ne '/BEGIN OpenVPN Static key/,$ p' /etc/openvpn/server/tc-"$server_mode".key
	echo "</tls-crypt>"
	} > ~/vpnuser/"$server_mode"/"$client".ovpn
}

if [[ ! -e /etc/openvpn/server/server-"$server_mode".conf ]]; then
	clear
	echo 'Welcome to this OpenVPN road warrior installer!'
	echo
	echo "I need to ask you a few questions before starting setup."
	echo "You can use the default options and just press enter if you are ok with them."
	# If system has a single IPv4, it is selected automatically. Else, ask the user
	if [[ $(ip -4 addr | grep inet | grep -vEc '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}') -eq 1 ]]; then
		ip=$(ip -4 addr | grep inet | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
	else
		number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
		echo
		echo "What IPv4 address should the OpenVPN server use?"
		ip -4 addr | grep inet | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | nl -s ') '
		read -p "IPv4 address [1]: " ip_number
		until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
			echo "$ip_number: invalid selection."
			read -p "IPv4 address [1]: " ip_number
		done
		[[ -z "$ip_number" ]] && ip_number="1"
		ip=$(ip -4 addr | grep inet | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sed -n "$ip_number"p)
	fi
	# If $ip is a private IP address, the server must be behind NAT
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo
		echo "This server is behind NAT. What is the public IPv4 address or hostname?"
		# Get public IP and sanitize with grep
		get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		# If the checkip service is unavailable and user didn't provide input, ask again
		until [[ -n "$get_public_ip" || -n $public_ip ]]; do
    		echo "Invalid input."
			read -p "Public IPv4 address / hostname: " public_ip
		done
		[[ -z "$public_ip" ]] && public_ip="$get_public_ip"
	fi
	#DISABLED IPv6
	## If system has a single IPv6, it is selected automatically
	#if [[ $(ip -6 addr | grep -c 'inet6 [23]') -eq 1 ]]; then
	#	ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}')
	#fi
	## If system has multiple IPv6, ask the user to select one
	#if [[ $(ip -6 addr | grep -c 'inet6 [23]') -gt 1 ]]; then
	#	number_of_ip6=$(ip -6 addr | grep -c 'inet6 [23]')
	#	echo
	#	echo "What IPv6 address should the OpenVPN server use?"
	#	ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | nl -s ') '
	#	read -p "IPv6 address [1]: " ip6_number
	#	until [[ -z "$ip6_number" || "$ip6_number" =~ ^[0-9]+$ && "$ip6_number" -le "$number_of_ip6" ]]; do
	#		echo "$ip6_number: invalid selection."
	#		read -p "IPv6 address [1]: " ip6_number
	#	done
	#	[[ -z "$ip6_number" ]] && ip6_number="1"
	#	ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | sed -n "$ip6_number"p)
	#fi
	echo
	echo "Which protocol do you want for OpenVPN connections?"
	echo "   1) UDP (recommended)"
	echo "   2) TCP"
	read -p "Protocol [1]: " protocol
	until [[ -z "$protocol" || "$protocol" =~ ^[12]$ ]]; do
		echo "$protocol: invalid selection."
		read -p "Protocol [1]: " protocol
	done
	case "$protocol" in
		1|"") 
		protocol=udp
		;;
		2) 
		protocol=tcp
		;;
	esac
	echo
	echo "What port do you want OpenVPN listening to?"
	read -p "Port [1194]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
		echo "$port: invalid port."
		read -p "Port [1194]: " port
	done
	[[ -z "$port" ]] && port="1194"
	echo
	echo "Which DNS do you want to use with the VPN?"
	echo "   1) Current system resolvers"
	echo "   2) 1.1.1.1"
	echo "   3) Google"
	echo "   4) OpenDNS"
	echo "   5) NTT"
	echo "   6) AdGuard"
	read -p "DNS [1]: " dns
	until [[ -z "$dns" || "$dns" =~ ^[1-6]$ ]]; do
		echo "$dns: invalid selection."
		read -p "DNS [1]: " dns
	done
	echo
	echo "Finally, tell me a name for the client certificate."
	read -p "Client name [client]: " unsanitized_client
	# Allow a limited set of characters to avoid conflicts
	client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
	[[ -z "$client" ]] && client="client"
	echo
	echo "Okay, that was all I needed. We are ready to set up your OpenVPN server now."
	read -n1 -r -p "Press any key to continue..."
	# If running inside a container, disable LimitNPROC to prevent conflicts
	if systemd-detect-virt -cq; then
		mkdir /etc/systemd/system/openvpn-server@server-"$server_mode".service.d/ 2>/dev/null
		echo "[Service]
LimitNPROC=infinity" > /etc/systemd/system/openvpn-server@server-"$server_mode".service.d/disable-limitnproc.conf
	fi
	if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
		apt-get update
		apt-get install -y openvpn iptables openssl ca-certificates
	elif [[ "$os" = "centos" ]]; then
		yum install -y epel-release
		yum install -y openvpn iptables openssl ca-certificates tar
	else
		# Else, OS must be Fedora
		dnf install -y openvpn iptables openssl ca-certificates tar
	fi
	# Get easy-rsa
	easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.7/EasyRSA-3.0.7.tgz'
	wget -O ~/easyrsa.tgz "$easy_rsa_url" 2>/dev/null || curl -Lo ~/easyrsa.tgz "$easy_rsa_url"
	tar xzf ~/easyrsa.tgz -C ~/
	mv ~/EasyRSA-3.0.7/ /etc/openvpn/server/
	mv /etc/openvpn/server/EasyRSA-3.0.7/ /etc/openvpn/server/easy-rsa-"$server_mode"/
	chown -R root:root /etc/openvpn/server/easy-rsa-"$server_mode"/
	rm -f ~/easyrsa.tgz
	cd /etc/openvpn/server/easy-rsa-"$server_mode"/
	# Create the PKI, set up the CA and the server and client certificates
	./easyrsa init-pki
	./easyrsa --batch build-ca nopass
	EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-server-full server nopass
	EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full "$client" nopass
	EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
	# Move the stuff we need
	cp pki/ca.crt /etc/openvpn/server/ca-"$server_mode".crt
	cp pki/private/ca.key /etc/openvpn/server/ca-"$server_mode".key
	cp pki/issued/server.crt /etc/openvpn/server/server-"$server_mode".crt
	cp pki/private/server.key /etc/openvpn/server/server-"$server_mode".key
	cp pki/crl.pem /etc/openvpn/server/crl-"$server_mode".pem
	##cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server
	# CRL is read with each client connection, when OpenVPN is dropped to nobody
	chown nobody:"$group_name" /etc/openvpn/server/crl-"$server_mode".pem
	# Generate key for tls-crypt
	openvpn --genkey --secret /etc/openvpn/server/tc-"$server_mode".key
	# Create the DH parameters file using the predefined ffdhe2048 group
	echo '-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----' > /etc/openvpn/server/dh-"$server_mode".pem
	# Generate server.conf
	echo "local $ip
port $port
proto $protocol
dev tun
ca ca.crt
cert server-${server_mode}.crt
key server-${server_mode}.key
dh dh-${server_mode}.pem
auth SHA512
tls-crypt tc-${server_mode}.key
topology subnet
server 10.8.0.0 255.255.255.0" > /etc/openvpn/server/server-"$server_mode".conf
	#DISABLED IPv6
	## IPv6
	#if [[ -z "$ip6" ]]; then
	#	echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server/server-"$server_mode".conf
	#else
	#	echo 'server-ipv6 fddd:1194:1194:1194::/64' >> /etc/openvpn/server/server-"$server_mode".conf
	#	echo 'push "redirect-gateway def1 ipv6 bypass-dhcp"' >> /etc/openvpn/server/server-"$server_mode".conf
	#fi
	echo 'ifconfig-pool-persist ipp.txt' >> /etc/openvpn/server/server-"$server_mode".conf
	# DNS
	case "$dns" in
		1|"")
			# Locate the proper resolv.conf
			# Needed for systems running systemd-resolved
			if grep -q "127.0.0.53" "/etc/resolv.conf"; then
				resolv_conf="/run/systemd/resolve/resolv.conf"
			else
				resolv_conf="/etc/resolv.conf"
			fi
			# Obtain the resolvers from resolv.conf and use them for OpenVPN
			grep -v '#' "$resolv_conf" | grep nameserver | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | while read line; do
				echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server/server-"$server_mode".conf
			done
		;;
		2)
			echo 'push "dhcp-option DNS 1.1.1.1"' >> /etc/openvpn/server/server-"$server_mode".conf
			echo 'push "dhcp-option DNS 1.0.0.1"' >> /etc/openvpn/server/server-"$server_mode".conf
		;;
		3)
			echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server/server-"$server_mode".conf
			echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server/server-"$server_mode".conf
		;;
		4)
			echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server/server-"$server_mode".conf
			echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server/server-"$server_mode".conf
		;;
		5)
			echo 'push "dhcp-option DNS 129.250.35.250"' >> /etc/openvpn/server/server-"$server_mode".conf
			echo 'push "dhcp-option DNS 129.250.35.251"' >> /etc/openvpn/server/server-"$server_mode".conf
		;;
		6)
			echo 'push "dhcp-option DNS 176.103.130.130"' >> /etc/openvpn/server/server-"$server_mode".conf
			echo 'push "dhcp-option DNS 176.103.130.131"' >> /etc/openvpn/server/server-"$server_mode".conf
		;;
	esac
	echo "keepalive 10 120
cipher AES-256-CBC
user nobody
group $group_name
persist-key
persist-tun
status openvpn-status-${server_mode}.log
verb 3
crl-verify crl-${server_mode}.pem" >> /etc/openvpn/server/server-"$server_mode".conf
	if [[ "$protocol" = "udp" ]]; then
		echo "explicit-exit-notify" >> /etc/openvpn/server/server-"$server_mode".conf
	fi
	# Enable net.ipv4.ip_forward for the system
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/30-openvpn-"$server_mode"-forward.conf
	# Enable without waiting for a reboot or service restart
	echo 1 > /proc/sys/net/ipv4/ip_forward
	#DISABLED IPv6
	#if [[ -n "$ip6" ]]; then
	#	# Enable net.ipv6.conf.all.forwarding for the system
	#	echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/30-openvpn-forward.conf
	#	# Enable without waiting for a reboot or service restart
	#	echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	#fi
	
	#TODO
	
	if pgrep firewalld; then
		# Using both permanent and not permanent rules to avoid a firewalld
		# reload.
		# We don't use --add-service=openvpn because that would only work with
		# the default port and protocol.
		firewall-cmd --add-port="$port"/"$protocol"
		firewall-cmd --zone=trusted --add-source=10.8."$subnet".0/24
		firewall-cmd --permanent --add-port="$port"/"$protocol"
		firewall-cmd --permanent --zone=trusted --add-source=10.8."$subnet".0/24
		if [[ $masquerade = 1 ]]; then
		  # Set NAT for the VPN subnet
		  firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8."$subnet".0/24 ! -d 10.8."$subnet".0/24 -j SNAT --to "$ip"
		  firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8."$subnet".0/24 ! -d 10.8."$subnet".0/24 -j SNAT --to "$ip"
		fi
		#DISABLED IPv6
		#if [[ -n "$ip6" ]]; then
		#	firewall-cmd --zone=trusted --add-source=fddd:1194:1194:1194::/64
		#	firewall-cmd --permanent --zone=trusted --add-source=fddd:1194:1194:1194::/64
		#	firewall-cmd --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
		#	firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
		#fi
	else
		# Create a service to set up persistent iptables rules
		if [[ $masquerade = 1 ]]; then
		  # Set NAT for the VPN subnet
		  firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8."$subnet".0/24 ! -d 10.8."$subnet".0/24 -j SNAT --to "$ip"
		  firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8."$subnet".0/24 ! -d 10.8."$subnet".0/24 -j SNAT --to "$ip"
		fi
		
		if [[ $masquerade = 1 ]]; then
			echo "[Unit]
Before=network.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables -t nat -A POSTROUTING -s 10.8.${subnet}.0/24 ! -d 10.8.${subnet}.0/24 -j SNAT --to $ip
ExecStart=/sbin/iptables -I INPUT -p $protocol --dport $port -j ACCEPT
ExecStart=/sbin/iptables -I FORWARD -s 10.8.${subnet}.0/24 -j ACCEPT
ExecStart=/sbin/iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=/sbin/iptables -t nat -D POSTROUTING -s 10.8.${subnet}.0/24 ! -d 10.8.${subnet}.0/24 -j SNAT --to $ip
ExecStop=/sbin/iptables -D INPUT -p $protocol --dport $port -j ACCEPT
ExecStop=/sbin/iptables -D FORWARD -s 10.8.${subnet}.0/24 -j ACCEPT
ExecStop=/sbin/iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" > /etc/systemd/system/openvpn-"$server_mode"-iptables.service
		else  
			echo "[Unit]
Before=network.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables -I INPUT -p $protocol --dport $port -j ACCEPT
ExecStart=/sbin/iptables -I FORWARD -s 10.8.${subnet}.0/24 -j ACCEPT
ExecStart=/sbin/iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=/sbin/iptables -D INPUT -p $protocol --dport $port -j ACCEPT
ExecStop=/sbin/iptables -D FORWARD -s 10.8.${subnet}.0/24 -j ACCEPT
ExecStop=/sbin/iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" > /etc/systemd/system/openvpn-"$server_mode"-iptables.service
		fi
		

		#DISABLED IPv6
		#if [[ -n "$ip6" ]]; then
		#	echo "ExecStart=/sbin/ip6tables -t nat -A POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ip6
#ExecStart=/sbin/ip6tables -I FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
#ExecStart=/sbin/ip6tables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
#ExecStop=/sbin/ip6tables -t nat -D POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ip6
#ExecStop=/sbin/ip6tables -D FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
#ExecStop=/sbin/ip6tables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" >> /etc/systemd/system/openvpn-"$server_mode"-iptables.service
		#fi
		echo "RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" >> /etc/systemd/system/openvpn-"$server_mode"-iptables.service
		systemctl enable --now openvpn-"$server_mode"-iptables.service
	fi
	# If SELinux is enabled and a custom port was selected, we need this
	if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
		# Install semanage if not already present
		if ! hash semanage 2>/dev/null; then
			if [[ "$os_version" -eq 7 ]]; then
				yum install -y policycoreutils-python
			else
				yum install -y policycoreutils-python-utils
			fi
		fi
		semanage port -a -t openvpn_port_t -p "$protocol" "$port"
	fi
	# If the server is behind NAT, use the correct IP address
	[[ ! -z "$public_ip" ]] && ip="$public_ip"
	# client-common.txt is created so we have a template to add further users later
	echo "client
dev tun
proto $protocol
remote $ip $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-CBC
ignore-unknown-option block-outside-dns
block-outside-dns
verb 3" > /etc/openvpn/server/client-"$server_mode"-common.txt
	# Enable and start the OpenVPN service
	systemctl enable --now openvpn-server@server-"$server_mode".service
	# Generates the custom client.ovpn
	new_client
	echo
	echo "Finished!"
	echo
	echo "Your client configuration is available at:" ~/vpnuser/"$server_mode"/"$client.ovpn"
	echo "If you want to add more clients, just run this script again!"
else
	clear
	echo "Looks like OpenVPN is already installed."
	echo
	echo "What do you want to do?"
	echo "   1) Add a new user (no password)"
	echo "   2) Revoke an existing user"
	echo "   3) Remove OpenVPN"
	echo "   4) Exit"
	echo "   5) Add a new user (with password)"
	read -p "Select an option: " option
	until [[ "$option" =~ ^[1-5]$ ]]; do
		echo "$option: invalid selection."
		read -p "Select an option: " option
	done
	case "$option" in
		1)
			echo
			echo "Tell me a name for the client certificate."
			read -p "Client name: " unsanitized_client
			client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			while [[ -z "$client" || -e /etc/openvpn/server/easy-rsa-"$server_mode"/pki/issued/"$client".crt ]]; do
				echo "$client: invalid client name."
				read -p "Client name: " unsanitized_client
				client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			done
			cd /etc/openvpn/server/easy-rsa-"$server_mode"/
			EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full "$client" nopass
			# Generates the custom client.ovpn
			new_client
			echo
			echo "Client $client added, configuration is available at:" ~/"$client.ovpn"
			exit
		;;
		2)
			# This option could be documented a bit better and maybe even be simplified
			# ...but what can I say, I want some sleep too
			number_of_clients=$(tail -n +2 /etc/openvpn/server/easy-rsa-"$server_mode"/pki/index.txt | grep -c "^V")
			if [[ "$number_of_clients" = 0 ]]; then
				echo
				echo "You have no existing clients!"
				exit
			fi
			echo
			echo "Select the existing client certificate you want to revoke:"
			tail -n +2 /etc/openvpn/server/easy-rsa-"$server_mode"/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			read -p "Select one client: " client_number
			until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
				echo "$client_number: invalid selection."
				read -p "Select one client: " client_number
			done
			client=$(tail -n +2 /etc/openvpn/server/easy-rsa-"$server_mode"/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$client_number"p)
			echo
			read -p "Do you really want to revoke access for client $client? [y/N]: " revoke
			until [[ "$revoke" =~ ^[yYnN]*$ ]]; do
				echo "$revoke: invalid selection."
				read -p "Do you really want to revoke access for client $client? [y/N]: " revoke
			done
			if [[ "$revoke" =~ ^[yY]$ ]]; then
				cd /etc/openvpn/server/easy-rsa-"$server_mode"/
				./easyrsa --batch revoke "$client"
				EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
				rm -f /etc/openvpn/server/crl-"$server_mode".pem
				cp /etc/openvpn/server/easy-rsa-"$server_mode"/pki/crl.pem /etc/openvpn/server/crl-"$server_mode".pem
				# CRL is read with each client connection, when OpenVPN is dropped to nobody
				chown nobody:"$group_name" /etc/openvpn/server/crl-"$server_mode".pem
				echo
				echo "Certificate for client $client revoked!"
			else
				echo
				echo "Certificate revocation for client $client aborted!"
			fi
			exit
		;;
		3)
			echo
			read -p "Do you really want to remove OpenVPN? [y/N]: " remove
			until [[ "$remove" =~ ^[yYnN]*$ ]]; do
				echo "$remove: invalid selection."
				read -p "Do you really want to remove OpenVPN? [y/N]: " remove
			done
			#TODO IPs
			if [[ "$remove" =~ ^[yY]$ ]]; then
				port=$(grep '^port ' /etc/openvpn/server/server-"$server_mode".conf | cut -d " " -f 2)
				protocol=$(grep '^proto ' /etc/openvpn/server/server-"$server_mode".conf | cut -d " " -f 2)
				if pgrep firewalld; then
					ip=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep '\-s 10.8.${subnet}.0/24 '"'"'!'"'"' -d 10.8.${subnet}.0/24' | grep -oE '[^ ]+$')
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --remove-port="$port"/"$protocol"
					firewall-cmd --zone=trusted --remove-source=10.8.${subnet}.0/24
					firewall-cmd --permanent --remove-port="$port"/"$protocol"
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.${subnet}.0/24
					firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.${subnet}.0/24 ! -d 10.8.${subnet}.0/24 -j SNAT --to "$ip"
					firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.${subnet}.0/24 ! -d 10.8.${subnet}.0/24 -j SNAT --to "$ip"
					#DISABLED IPv6
					#if grep -qs "server-ipv6" /etc/openvpn/server/server.conf; then
					#	ip6=$(firewall-cmd --direct --get-rules ipv6 nat POSTROUTING | grep '\-s fddd:1194:1194:1194::/64 '"'"'!'"'"' -d fddd:1194:1194:1194::/64' | grep -oE '[^ ]+$')
					#	firewall-cmd --zone=trusted --remove-source=fddd:1194:1194:1194::/64
					#	firewall-cmd --permanent --zone=trusted --remove-source=fddd:1194:1194:1194::/64
					#	firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
					#	firewall-cmd --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
					#fi
				else
					systemctl disable --now openvpn-"$server_mode"-iptables.service
					rm -f /etc/systemd/system/openvpn-"$server_mode"-iptables.service
				fi
				if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
					semanage port -d -t openvpn_port_t -p "$protocol" "$port"
				fi
				systemctl disable --now openvpn-server@server-"$server_mode".service
				#rm -rf /etc/openvpn/server
				rm -f /etc/systemd/system/openvpn-server@server-"$server_mode".service.d/disable-limitnproc.conf
				rm -f /etc/sysctl.d/30-openvpn-"$server_mode"-forward.conf
				#if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
				#	apt-get remove --purge -y openvpn
				#else
				#	# Else, OS must be CentOS or Fedora
				#	yum remove -y openvpn
				#fi
				echo
				echo "OpenVPN removed partially! You still need to clear /etc/openvpn/server directory and remove openvpn package"
			else
				echo
				echo "Removal aborted!"
			fi
			exit
		;;
		4)
			exit
		;;
		5)
			echo
			echo "Tell me a name for the client certificate."
			read -p "Client name: " unsanitized_client
			client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			while [[ -z "$client" || -e /etc/openvpn/server/easy-rsa-"$server_mode"/pki/issued/"$client".crt ]]; do
				echo "$client: invalid client name."
				read -p "Client name: " unsanitized_client
				client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			done
			cd /etc/openvpn/server/easy-rsa-"$server_mode"/
			EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full "$client"
			# Generates the custom client.ovpn
			new_client
			echo
			echo "Client $client added, configuration is available at:" ~/"$client.ovpn"
			exit
		;;
	esac
fi
