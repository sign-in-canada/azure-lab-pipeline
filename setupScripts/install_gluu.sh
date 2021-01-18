#!/bin/bash
if [ "$#" -ne 1 ]; then
    echo "Please specify Couchbase IP"
    echo "./install.sh 10.0.1.4"
    exit
fi

TARBALL="SIC-AP-0.0.223"
KEYVAULT="https://kv-sic-dev-00.vault.azure.net"

# set the hostname
echo "Setting the hostname"
zayn=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2017-08-01&format=text")
hostname ${zayn}.id.alpha.canada.ca

# Install epel and jq
yum clean all
yum install -y epel-release
yum install -y jq

# isntall gluu GPG key TODO: Use alternate supply path
echo "Setting up Gluuu GPG key"
wget https://repo.gluu.org/rhel/RPM-GPG-KEY-GLUU -O /etc/pki/rpm-gpg/RPM-GPG-KEY-GLUU
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-GLUU


# TODO: Have the Custom Script Extension do this
echo "Downloading Software"
wget https://repo.gluu.org/centos/7/gluu-server-4.2.2-centos7.x86_64.rpm
wget https://raw.githubusercontent.com/sign-in-canada/Admin-Tools/develop/software/install.sh

echo "Running SIC setup"
export STAGING_URL=https://sicqa.blob.core.windows.net/staging
export KEYVAULT_URL=${KEYVAULT}
export METADATA_URL=https://sicqa.blob.core.windows.net/saml/SIC-Nonprod-signed.xml
export CB_HOSTS=${1}

sh ./install.sh ${TARBALL}