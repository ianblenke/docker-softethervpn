#!/bin/bash
set -e

if [ ! -f /opt/vpn_server.config ]; then

: ${PSK:='notasecret'}
: ${USERNAME:=user$(cat /dev/urandom | tr -dc '0-9' | fold -w 4 | head -n 1)}

printf '# '
printf '=%.0s' {1..24}
echo
echo \# ${USERNAME}

if [[ $PASSWORD ]]
then
  echo '# <use the password specified at -e PASSWORD>'
else
  PASSWORD=$(cat /dev/urandom | tr -dc '0-9' | fold -w 20 | head -n 1 | sed 's/.\{4\}/&./g;s/.$//;')
  echo \# ${PASSWORD}
fi  

printf '# '
printf '=%.0s' {1..24}
echo

/opt/vpnserver start 2>&1 > /dev/null

# while-loop to wait until server comes up
# switch cipher
while : ; do
  set +e
  /opt/vpncmd localhost /SERVER /CSV /CMD ServerCipherSet DHE-RSA-AES256-SHA 2>&1 > /dev/null
  [[ $? -eq 0 ]] && break
  set -e
  sleep 1
done

# enable L2TP_IPsec
/opt/vpncmd localhost /SERVER /CSV /CMD IPsecEnable /L2TP:${IPSECENABLE_L2TP:-yes} /L2TPRAW:${IPSECENABLE_L2TPRAW:-yes} /ETHERIP:${IPSECENABLE_ETHERIP:-no} /PSK:${PSK} /DEFAULTHUB:DEFAULT

# enable SecureNAT
/opt/vpncmd localhost /SERVER /CSV /HUB:DEFAULT /CMD SecureNatEnable

# fix DNS in the DHCP scope
/opt/vpncmd localhost /SERVER /CSV /HUB:DEFAULT /CMD DhcpSet /START:${DHCPSET_START:-192.168.30.10} /END:${DHCPSET_END:-192.168.30.250} /MASK:${DHCPSET_MASK:-255.255.255.0} /EXPIRE:${DHCPSET_EXPIRE:-86400} /GW:${DHCPSET_GW:-192.168.30.1} /DNS:${DHCPSET_DNS:-8.8.8.8} /DNS2:${DHCPSET_DNS2:-8.8.4.4} /DOMAIN:${DHCPSET_LOCAL:-local} /LOG:${DHCPSET_LOG:-yes}

# enable OpenVPN
/opt/vpncmd localhost /SERVER /CSV /CMD OpenVpnEnable yes /PORTS:1194

if [[ "*${CERT}*" != "**" && "*${KEY}*" != "**" ]]; then
  # server cert/key pair specified via -e
  CERT=$(echo ${CERT} | sed -r 's/\-{5}[^\-]+\-{5}//g;s/[^A-Za-z0-9\+\/\=]//g;')
  echo -----BEGIN CERTIFICATE----- > server.crt
  echo ${CERT} | fold -w 64 >> server.crt
  echo -----END CERTIFICATE----- >> server.crt

  KEY=$(echo ${KEY} | sed -r 's/\-{5}[^\-]+\-{5}//g;s/[^A-Za-z0-9\+\/\=]//g;')
  echo -----BEGIN PRIVATE KEY----- > server.key
  echo ${KEY} | fold -w 64 >> server.key
  echo -----END PRIVATE KEY----- >> server.key

  /opt/vpncmd localhost /SERVER /CSV /CMD ServerCertSet /LOADCERT:server.crt /LOADKEY:server.key
  rm server.crt server.key
  export KEY='**'
fi

/opt/vpncmd localhost /SERVER /CSV /CMD OpenVpnMakeConfig openvpn.zip 2>&1 > /dev/null

# extract .ovpn config
unzip -p openvpn.zip *_l3.ovpn > softether.ovpn
# delete "#" comments, \r, and empty lines
sed -i '/^#/d;s/\r//;/^$/d' softether.ovpn
# send to stdout
cat softether.ovpn

# add user
/opt/vpncmd localhost /SERVER /HUB:DEFAULT /CSV /CMD UserCreate ${USERNAME} /GROUP:none /REALNAME:none /NOTE:none
/opt/vpncmd localhost /SERVER /HUB:DEFAULT /CSV /CMD UserPasswordSet ${USERNAME} /PASSWORD:${PASSWORD}

export PASSWORD='**'

# set password for hub
if [ -z "${HUB_PASSWORD}" ]; then
  HUB_PASSWORD=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | fold -w 16 | head -n 1)
  echo HubPassword: ${HUB_PASSWORD}
fi
/opt/vpncmd localhost /SERVER /HUB:DEFAULT /CSV /CMD SetHubPassword ${HUB_PASSWORD}

# set password for server
if [ -z "${SERVER_PASSWORD}" ]; then
  SERVER_PASSWORD=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | fold -w 20 | head -n 1)
  echo ServerPassword: ${SERVER_PASSWORD}
fi
/opt/vpncmd localhost /SERVER /CSV /CMD ServerPasswordSet ${SERVER_PASSWORD}

/opt/vpnserver stop 2>&1 > /dev/null

tail -f /opt/*log/* /opt/*log/*/* 2>/dev/null &

# while-loop to wait until server goes away
set +e
while pgrep vpnserver > /dev/null; do sleep 1; done
set -e

echo \# [initial setup OK]

fi

exec "$@"

