#!/bin/bash

# isntall gluu server 
echo "setting up repos for gluu"
wget https://repo.gluu.org/rhel/Gluu-rhel7.repo -O /etc/yum.repos.d/Gluu.repo
wget https://repo.gluu.org/rhel/RPM-GPG-KEY-GLUU -O /etc/pki/rpm-gpg/RPM-GPG-KEY-GLUU
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-GLUU
yum clean all

# update hosts file with hostname and IP addresses
echo "updating hosts file with hostname and IP addresses"

zayn=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2017-08-01&format=text")
hostname="${zayn}.canadacentral.cloudapp.azure.com"
ip=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2017-08-01&format=text")
privateIP=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2017-08-01&format=text")
sed -i.bkp "$ a $ip $hostname" /etc/hosts
sed -i.bkp "$ a $privateIP $hostname" /etc/hosts
echo > /etc/hostname
echo $hostname > /etc/hostname

echo "install azure cli"
rpm --import https://packages.microsoft.com/keys/microsoft.asc

sh -c 'echo -e "[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'

yum install -y azure-cli
echo "installing JQ"
yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
yum install -y jq

echo "setting up ACME script"
yum install -y socat
curl https://get.acme.sh | sh
#exec bash
/.acme.sh/acme.sh --issue --standalone -d $hostname

echo "gluu server install begins"
mkdir staging && cd staging
wget https://repo.gluu.org/centos/7/gluu-server-4.1.0-centos7.x86_64.rpm
rpm -Uvh gluu-server-4.1.0-centos7.x86_64.rpm
#echo "updating the timeouts"
#sed -i "s/# jetty.server.stopTimeout=5000/jetty.server.stopTimeout=15000/g" /opt/gluu-server/opt/gluu/jetty/identity/start.ini
#sed -i "s/# jetty.http.connectTimeout=15000/jetty.http.connectTimeout=15000/g" /opt/gluu-server/opt/gluu/jetty/identity/start.ini

echo "enabling gluu server and logging into container"
/sbin/gluu-serverd enable
/sbin/gluu-serverd start

echo "downloading SIC tarball"
wget https://gluuccrgdiag.blob.core.windows.net/gluu/SIC-Admintools-0.0.132.tgz
wget https://gluuccrgdiag.blob.core.windows.net/gluu/SIC-AP-0.0.132.tgz
tar -xvf SIC-AP-0.0.132.tgz
tar -xvf SIC-Admintools-0.0.132.tgz

API_VER='7.0'
# Obtain an access token
TOKEN=$(curl -s 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -H Metadata:true | jq -r '.access_token')

RGNAME=$(curl -s 'http://169.254.169.254/metadata/instance/compute/resourceGroupName?api-version=2020-06-01&format=text' -H Metadata:true)
KEYVAULT="https://${RGNAME}-keyvault.vault.azure.net"

SASTOKEN=$(curl -s -H "Authorization: Bearer ${TOKEN}" ${KEYVAULT}/secrets/StorageSaSToken?api-version=${API_VER} | jq -r '.value')

wget -O setup.properties "https://gluuccrgdiag.blob.core.windows.net/gluu-install/setup.properties?${SASTOKEN}"

cp setup.properties /opt/gluu-server/install/community-edition-setup/

ssh  -o IdentityFile=/etc/gluu/keys/gluu-console -o Port=60022 -o LogLevel=QUIET \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o PubkeyAuthentication=yes root@localhost \
            "/install/community-edition-setup/setup.py -n -f setup.properties"

if [ ! -f /opt/gluu-server/install/community-edition-setup/setup.py ] ; then
   echo "Gluu setup install failed. Aborting!"
   exit
fi

