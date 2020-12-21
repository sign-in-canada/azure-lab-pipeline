#!/bin/bash

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

echo "pre-installation steps"
mkdir /etc/tuned/no-thp
cat > /etc/tuned/no-thp/tuned.conf <<EOF
[main]
include=virtual-guest

[vm]
transparent_hugepages=never
EOF
tuned-adm profile no-thp

sh -c 'echo 0 > /proc/sys/vm/swappiness'
cp -p /etc/sysctl.conf /etc/sysctl.conf.`date +%Y%m%d-%H:%M`
sh -c 'echo "" >> /etc/sysctl.conf'
sh -c 'echo "#Set swappiness to 0 to avoid swapping" >> /etc/sysctl.conf'
sh -c 'echo "vm.swappiness = 0" >> /etc/sysctl.conf'

yum install -y jq 

echo "install couchbase"  
curl -O https://packages.couchbase.com/releases/couchbase-release/couchbase-release-1.0-x86_64.rpm
sudo rpm -i ./couchbase-release-1.0-x86_64.rpm
sudo yum -y install couchbase-server

echo "waiting for services to start"
sleep 30

echo "setup cluster"
curl -v -X POST http://localhost:8091/settings/indexes -d 'storageMode=memory_optimized'
curl -v -X POST http://localhost:8091/pools/default -d memoryQuota=2048 -d indexMemoryQuota=512
curl -v http://localhost:8091/node/controller/setupServices -d services=kv%2cn1ql%2Cindex
curl -v http://localhost:8091/settings/web -d port=8091 -d username=Administrator -d password=${1}

echo "setting up ACME script"
yum install -y socat
curl https://get.acme.sh | sh
exec bash
/.acme.sh/acme.sh --issue --standalone -d $hostname