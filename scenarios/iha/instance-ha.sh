#!/bin/bash

echo "Run instance HA test"
. overcloudrc
NAME=$(openstack server list -f csv -c Name --quote none|grep -v ^Name)
HYPERVISOR=$(openstack server show $NAME -f value -c "OS-EXT-SRV-ATTR:hypervisor_hostname")
IP=$(openstack hypervisor list -f csv --quote none | grep $HYPERVISOR | cut -d, -f4)
echo "About to reset $IP"

