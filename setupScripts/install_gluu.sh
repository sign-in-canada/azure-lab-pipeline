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

cat /.acme.sh/$hostname/$hostname.key /.acme.sh/$hostname/fullchain.cer > httpd

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

API_VER='7.0'
# Obtain an access token
TOKEN=$(curl -s 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -H Metadata:true | jq -r '.access_token')

RGNAME=$(curl -s 'http://169.254.169.254/metadata/instance/compute/resourceGroupName?api-version=2020-06-01&format=text' -H Metadata:true)
KEYVAULT="https://${RGNAME}-keyvault.vault.azure.net"

SASTOKEN=$(curl -s -H "Authorization: Bearer ${TOKEN}" ${KEYVAULT}/secrets/StorageSaSToken?api-version=${API_VER} | jq -r '.value')

wget -O setup.properties "https://siccommonstorage.blob.core.windows.net/sic-pipeline-artifacts-private/setup.properties?${SASTOKEN}"

echo "update hostname of the gluu server"
sed -i "/^hostname=/ s/.*/hostname=$hostname/g" setup.properties

echo "copying setup.props file to gluu container"
cp setup.properties /opt/gluu-server/install/community-edition-setup/

echo "copying certs to gluu container"
KV_DIR=/opt/gluu-server/install/keyvault/certs
mkdir -p $KV_DIR
cp /.acme.sh/$hostname/* $KV_DIR
cat $hostname > $KV_DIR/hostname_

ssh  -o IdentityFile=/etc/gluu/keys/gluu-console -o Port=60022 -o LogLevel=QUIET \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o PubkeyAuthentication=yes root@localhost \
            "/install/community-edition-setup/setup.py -n -f setup.properties"

if [ ! -f /opt/gluu-server/install/community-edition-setup/setup.py ] ; then
   echo "Gluu setup install failed. Aborting!"
   exit
fi

#curl -s -H "Authorization: Bearer ${TOKEN}" -F file=@"httpd" https://${RGNAME}-keyvault.vault.azure.net/certificates/httpd/import?api-version=7.1

sed -i "/^loadData=True/ s/.*/loadData=False/g" setup.properties

echo "downloading SIC tarball"
wget https://siccommonstorage.blob.core.windows.net/sic-pipeline-artifacts-public/SIC-Admintools-0.0.26.tgz
wget https://siccommonstorage.blob.core.windows.net/sic-pipeline-artifacts-public/SIC-AP-0.0.205.tgz

tar -xvf SIC-Admintools-0.0.26.tgz

cp software/install.sh .
chmod +x install.sh
cat > install.params <<EOF
STAGING_URL=https://siccommonstorage.blob.core.windows.net/sic-pipeline-artifacts-public
KEYVAULT_URL=${KEYVAULT}
METADATA_URL=https://sicqa.blob.core.windows.net/saml/SIC-Nonprod-signed.xml
EOF

sh install.sh SIC-AP-0.0.205