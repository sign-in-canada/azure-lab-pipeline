#!/bin/bash

echo "Setting the host name"
vmname=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2020-10-01&format=text")
hostname ${vmname,,}.internal.cloudapp.net

echo "Installing jq"
yum clean all
yum install -y epel-release
yum install -y jq

fetchTag () {
  curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2020-10-01" | jq -r ".[] | select(.name == \"${1}\") | .value"
}

if [ -z "$product"] ; then
  product=$(fetchTag PRODUCT)
fi

if [ -z "$environment"] ; then
  environment=$(fetchTag ENVIRONMENT)
fi

if [ -z "$keyvault" ] ; then
  keyvault="https://$(fetchTag KEYVAULT).vault.azure.net"
fi

echo "Installing Cochbase for:"
echo "  product: $product"
echo "  environment: $environment"
echo
echo "Using keyvault: $keyvault"

if [ ! -d /etc/tuned/no-thp ] ; then
  echo "pre-installation steps"
  mkdir /etc/tuned/no-thp
  cat > /etc/tuned/no-thp/tuned.conf <<-EOF
	[main]
	include=virtual-guest

	[vm]
	transparent_hugepages=never
	EOF

  tuned-adm profile no-thp

  echo 0 > /proc/sys/vm/swappiness
  cp -p /etc/sysctl.conf /etc/sysctl.conf.`date +%Y%m%d-%H:%M`
  echo >> /etc/sysctl.conf
  echo "#Set swappiness to 0 to avoid swapping" >> /etc/sysctl.conf
  echo "vm.swappiness = 0" >> /etc/sysctl.conf
fi

# Obtain keyvault access token
token=$(curl -s 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -H Metadata:true | jq -r '.access_token')

fetchSecret () {
   curl -s -H "Authorization: Bearer ${token}" ${keyvault}/secrets/${1}?api-version=7.1 | jq -r '.value'
}

# Verify keyvault connectivity before going any further
if fetchSecret 'x' > /dev/null 2>&1 ; then
   echo "Connected to keyvault ${keyvault}"
else
   echo "Connection to keyvault ${keyvault} failed. Aborting."
   exit 1
fi

# Get the admin password from keyvault
export CB_REST_USERNAME=Administrator
salt=$(fetchSecret ${product}Salt)
key=$(echo -n $salt | hexdump -ve '1/1 "%.2x"')
export CB_REST_PASSWORD=$(fetchSecret ${product}GluuPW | openssl enc -d -des-ede3 -K ${key} -nosalt -a)

echo "install Couchbase"  
#sudo yum install -y https://packages.couchbase.com/releases/couchbase-release/couchbase-release-1.0-x86_64.rpm
curl -O https://packages.couchbase.com/releases/couchbase-release/couchbase-release-1.0-x86_64.rpm
sudo rpm -i ./couchbase-release-1.0-x86_64.rpm
sudo yum install -y couchbase-server

echo "waiting for services to start"
sleep 30

echo "setup cluster"
total_mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
if [ $total_mem -gt 10240000 ] ; then
  data_mem=$(( $total_mem*50/100000 ))
  index_mem=$(( $total_mem*30/100000 ))
else
  data_mem=2048
  index_mem=512
fi

/opt/couchbase/bin/couchbase-cli node-init -c couchbase://localhost \
--node-init-hostname $(hostname)

/opt/couchbase/bin/couchbase-cli cluster-init -c couchbase://localhost \
--cluster-name ${environment}-$product \
--cluster-username Administrator \
--cluster-password $CB_REST_PASSWORD \
--services data,index,query \
--cluster-ramsize $data_mem \
--cluster-index-ramsize $index_mem \
--update-notifications 0

echo "apply hardening"

/opt/couchbase/bin/couchbase-cli  setting-autofailover -c couchbase://localhost --enable-auto-failover 0

/opt/couchbase/bin/couchbase-cli  node-to-node-encryption -c couchbase://localhost --enable

/opt/couchbase/bin/couchbase-cli setting-security -c couchbase://localhost --set \
  --disable-http-ui 1 \
  --tls-min-version tlsv1.2 \
  --set --tls-honor-cipher-order 1 \
  --cipher-suites TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 \
  --cluster-encryption-level all

/opt/couchbase/bin/couchbase-cli  setting-autofailover -c couchbase://localhost \
  --enable-auto-failover 1 \
  --auto-failover-timeout 120 \
  --enable-failover-of-server-groups 1 \
  --max-failovers 2 \
  --can-abort-rebalance 1

/opt/couchbase/bin/couchbase-cli  setting-audit -c couchbase://localhost \
  --set --audit-enabled 1

# Enable session timeout on the Admin Console
curl -X POST -u Administrator:${CB_REST_PASSWORD} \
  http://localhost:8091/settings/security \
  -d "uiSessionTimeout=600"

# Remove unused JRE
rm -rf /opt/couchbase/lib/cbas/runtime

echo "Create gluu user"
/opt/couchbase/bin/couchbase-cli user-manage -c couchbase://localhost \
--set \
--rbac-username gluu \
--rbac-password $CB_REST_PASSWORD \
--roles admin \
--auth-domain local

if [ "$product" == "AP" ] ; then
  echo "Create Shibboleth user"
  /opt/couchbase/bin/couchbase-cli user-manage -c couchbase://localhost \
    --set \
    --rbac-username couchbaseShibUser \
    --rbac-password $(fetchSecret APShibPW) \
    --roles 'query_select[*]' \
    --auth-domain local
fi

echo "Updating packages"
#yum update -y
echo "Couchbase cluster ${environment}-$product has been created on $(hostname)"