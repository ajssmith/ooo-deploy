#!/bin/bash
set -x

function undercloud_upgrade() {
	echo "Undercloud upgrade"
	mkdir /home/stack/REPOBACKUP
	sudo mv /etc/yum.repos.d/delorean* /home/stack/REPOBACKUP/

	sudo systemctl stop openstack-*
	sudo systemctl stop neutron-*
	sudo systemctl stop openvswitch
	sudo systemctl stop httpd

	sudo curl -L -o /etc/yum.repos.d/delorean-pike.repo https://trunk.rdoproject.org/centos7-pike/current/delorean.repo
	sudo curl -L -o /etc/yum.repos.d/delorean-deps-pike.repo https://trunk.rdoproject.org/centos7-pike/delorean-deps.repo
	# Check pre-upgrade undercloud validation
	#openstack workflow execution create tripleo.validations.v1.run_groups '{"group_names": ["pre-upgrade"]}'
	#mistral execution-get-output 8eedd56a-7f56-410f-9fa4-6ab7c0596688
	sudo yum -y install --enablerepo=extras centos-release-ceph-jewel
	sudo yum -y install ceph-ansible
	sudo yum -y update python-openstackclient python-tripleoclient ceph-ansible
	openstack undercloud upgrade

	# Make sure overcloud can reach the internet
	sudo ifup vlan10
	sudo iptables -t nat -A BOOTSTACK_MASQ -j MASQUERADE
}

function checkout_pike_tht_and_repos() {
# At this point undercloud is updated
# Prepare repo updating command
cat > /home/stack/overcloud-repos.yaml <<EOF
parameter_defaults:
  UpgradeInitCommand: |
    set -e
    mv /etc/yum.repos.d/delorean* /root/
    curl -L -o /etc/yum.repos.d/delorean-pike.repo https://trunk.rdoproject.org/centos7-pike/current/delorean.repo
    curl -L -o /etc/yum.repos.d/delorean-deps-pike.repo https://trunk.rdoproject.org/centos7-pike/delorean-deps.repo
EOF
	# Switch templates /home/stack/tripleo-heat-templates/ to ocata
	cp tripleo-heat-templates ocata-tripleo-heat-templates -rdp
	pushd tripleo-heat-templates/
	git checkout origin/stable/pike -b local-pike
        popd
}

function get_containers() {
	#Upstream CI uses:
	# http://logs.openstack.org/25/500625/15/check/legacy-tripleo-ci-centos-7-containers-multinode-upgrades/2a547a7/logs/undercloud/home/zuul/overcloud-upgrade.sh
	# we need to do the whole container download thing + upload
	# as a first step
	# pull latest containers to the registry
	sudo bash -c "source /home/stack/stackrc; openstack overcloud container image prepare \
	    --images-file /home/stack/overcloud_upgrade_containers.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/docker.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/docker-ha.yaml \
	    --namespace docker.io/tripleopike \
	    --tag current-tripleo \
	    --push-destination 192.168.24.1:8787"
	    

	sudo bash -c "source /home/stack/stackrc; openstack overcloud container image prepare \
	    --env-file /home/stack/containers-default-parameters.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/docker.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/docker-ha.yaml \
	    --namespace docker.io/tripleopike \
	    --tag current-tripleo"

        sudo bash -c "source /home/stack/stackrc; openstack overcloud container image upload --verbose --config-file /home/stack/overcloud_upgrade_containers.yaml"
	echo "  DockerInsecureRegistryAddress: 192.168.24.1:8787" >> \
	    ~/containers-default-parameters.yaml
}

undercloud_upgrade

# Test if ironic and nova work
source /home/stack/stackrc
ironic node-list
nova list

checkout_pike_tht_and_repos
get_containers

# Rebase any custom_roles.yaml files
mv custom_roles.yaml custom_roles.yaml.ocata
cp /home/stack/tripleo-heat-templates/roles_data.yaml custom_roles.yaml

# Do the actual upgrade
openstack overcloud deploy \
 --templates /home/stack/tripleo-heat-templates \
 --libvirt-type qemu --timeout 80 -e /home/stack/cloud-names.yaml \
 -e /home/stack/tripleo-heat-templates/environments/debug.yaml \
 -e /home/stack/tripleo-heat-templates/environments/network-isolation.yaml \
 -e /home/stack/tripleo-heat-templates/environments/net-single-nic-with-vlans.yaml \
 -e /home/stack/network-environment.yaml  -e /home/stack/tripleo-heat-templates/environments/low-memory-usage.yaml \
 -e /home/stack/tripleo-heat-templates/environments/disable-telemetry.yaml \
 -e /home/stack/fencing_config.yaml \
 --validation-errors-nonfatal \
 --roles-file /home/stack/custom_roles.yaml \
 --control-scale 3 --compute-scale 2 \
 -e /home/stack/tripleo-heat-templates/environments/docker.yaml \
 -e /home/stack/tripleo-heat-templates/environments/docker-ha.yaml \
 -e /home/stack/custom_stuff.yaml \
 -e /home/stack/tripleo-heat-templates/environments/major-upgrade-composable-steps-docker.yaml \
 -e ~/containers-default-parameters.yaml \
 -e ~/overcloud-repos.yaml

# Do the actual converge step:
if openstack stack show overcloud | grep "stack_status " | egrep "(CREATE|UPDATE)_COMPLETE"; then
	openstack overcloud deploy \
	    --templates /home/stack/tripleo-heat-templates \
	    --libvirt-type qemu --timeout 80 -e /home/stack/cloud-names.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/debug.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/network-isolation.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/net-single-nic-with-vlans.yaml \
	    -e /home/stack/network-environment.yaml  -e /home/stack/tripleo-heat-templates/environments/low-memory-usage.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/disable-telemetry.yaml \
	    -e /home/stack/fencing_config.yaml \
	    --validation-errors-nonfatal \
	    --roles-file /home/stack/custom_roles.yaml \
	    --control-scale 3 --compute-scale 2 \
	    -e /home/stack/tripleo-heat-templates/environments/docker.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/docker-ha.yaml \
	    -e /home/stack/custom_stuff.yaml \
	    -e /home/stack/tripleo-heat-templates/environments/major-upgrade-converge-docker.yaml \
	    -e ~/containers-default-parameters.yaml
fi

