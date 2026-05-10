#!/bin/bash

#CONFIG
IF_CFG='/etc/network/interfaces'
RESOLV='/etc/resolv.conf'
HOSTNAME='vm1'

#IMPORT VAR
source $(dirname $0)/vm1.config

################ CONFIG ETHER INTERFACE ######################
echo '# Config interfaces
source /etc/network/interfaces.d/*
# The loopback network interface
auto lo
iface lo inet loopback
' > $IF_CFG
####################### EXTERNAL ##############################
echo '# External interface' >> $IF_CFG
if [ "$EXT_IP" = "DHCP" ]; then
###### IF DHCP ######
echo "auto  $EXTERNAL_IF
iface $EXTERNAL_IF inet dhcp
" >> $IF_CFG
route del default
dhclient $EXTERNAL_IF
###### IF MAN #######
else
echo "auto  $EXTERNAL_IF
iface $EXTERNAL_IF inet static
address $EXT_IP
gateway $EXT_GW
dns-nameservers 8.8.8.8
dns-nameservers 8.8.4.4
" >> $IF_CFG
ifconfig $EXTERNAL_IF $EXT_IP
route del default
route add default gw $EXT_GW
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf; fi
###############################################################

######################## INTERNAL #############################
echo '# Internal interface' >> $IF_CFG
echo "auto  $INTERNAL_IF
iface $INTERNAL_IF inet static
address $INT_IP
" >> $IF_CFG
ifconfig $INTERNAL_IF $INT_IP
###############################################################

###################### INTERNAL VLAN ##########################
echo '# Internal interface vlan' >> $IF_CFG
echo "auto  $INTERNAL_IF.$VLAN
iface $INTERNAL_IF.$VLAN inet static
address $VLAN_IP
vlan-raw-device $INTERNAL_IF
" >> $IF_CFG
apt install vlan -y
modprobe 8021q
vconfig add $INTERNAL_IF $VLAN
ifconfig $INTERNAL_IF.$VLAN $VLAN_IP
###############################################################

###################### SYS CONFIG #############################
CUR_IP=$(ifconfig $EXTERNAL_IF | grep 'inet addr' | cut -d: -f2 | awk '{print $1}')
hostname $HOSTNAME
echo $CUR_IP $HOSTNAME > /etc/hosts
###############################################################

######################### NAT #################################
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -A INPUT -i lo -j ACCEPT
iptables -A FORWARD -i $INTERNAL_IF -o $EXTERNAL_IF -j ACCEPT
iptables -A FORWARD -i $EXTERNAL_IF -o $INTERNAL_IF -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -o $EXTERNAL_IF -j MASQUERADE
###############################################################

################# CERT CREATE CONFIG ##########################
echo "
[ req ]
default_bits                = 4096
default_keyfile             = privkey.pem
distinguished_name          = req_distinguished_name
req_extensions              = v3_req
 
[ req_distinguished_name ]
countryName                 = Country Name (2 letter code)
countryName_default         = UK
stateOrProvinceName         = State or Province Name (full name)
stateOrProvinceName_default = Wales
localityName                = Locality Name (eg, city)
localityName_default        = Cardiff
organizationName            = Organization Name (eg, company)
organizationName_default    = Example UK
commonName                  = Common Name (eg, YOUR name)
commonName_default          = one.test.app.example.net
commonName_max              = 64
 
[ v3_req ]
basicConstraints            = CA:FALSE
keyUsage                    = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName              = @alt_names
 
[alt_names]
IP.1   = $CUR_IP
DNS.1   = $HOSTNAME" > /usr/lib/ssl/openssl-san.cnf 

################# CERT GENERATE KEY ###########################
openssl genrsa -out /etc/ssl/certs/root-ca.key 4096
openssl req -x509 -new -key /etc/ssl/certs/root-ca.key -days 365 -out /etc/ssl/certs/root-ca.crt -subj "/C=UA/L=Kharkov/O=DLNet/OU=NOC/CN=dlnet.kharkov.com"
openssl genrsa -out /etc/ssl/certs/web.key 4096
openssl req -new -key /etc/ssl/certs/web.key -out /etc/ssl/certs/web.csr -config /usr/lib/ssl/openssl-san.cnf -subj "/C=UA/L=Kharkov/O=DLNet/OU=NOC/CN=$HOSTNAME"
openssl x509 -req -in /etc/ssl/certs/web.csr -CA /etc/ssl/certs/root-ca.crt  -CAkey /etc/ssl/certs/root-ca.key -CAcreateserial -out /etc/ssl/certs/web.crt -days 365 -extensions v3_req -extfile /usr/lib/ssl/openssl-san.cnf
cat /etc/ssl/certs/root-ca.crt >> /etc/ssl/certs/web.crt
###############################################################

################### NGINX INSTALL##############################
apt update && apt install nginx -y
###############################################################

################### NGINX CONFIG ##############################
rm -r /etc/nginx/sites-enabled/*
cp /etc/nginx/sites-available/default  /etc/nginx/sites-available/$HOSTNAME
echo '### CONFIG ###' > /etc/nginx/sites-available/$HOSTNAME
echo "
upstream $HOSTNAME {
server $APACHE_VLAN_IP:80;
}
server {
listen  $CUR_IP:80;
server_name $HOSTNAME;
return 444;
}
server {
listen  $CUR_IP:$NGINX_PORT ssl;
server_name $HOSTNAME;
ssl on;
ssl_certificate /etc/ssl/certs/web.crt;
ssl_certificate_key /etc/ssl/certs/web.key;
 location / {
            proxy_pass http://$HOSTNAME;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
	}
} " >> /etc/nginx/sites-available/$HOSTNAME
ln -s /etc/nginx/sites-available/$HOSTNAME /etc/nginx/sites-enabled/$HOSTNAME

##################### APLY ##################################
echo "###### done ######" && systemctl restart nginx
#############################################################
exit $?
