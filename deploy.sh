#!/bin/bash
set -eux

if [ "$#" -ne 3 ]; then
    echo "Pass host, release and type of deploy as a parameter."
    echo "where release [pike,master]" 2>&1
    echo "where deploy [ipv6,iha,ssl]" 2>&1
    echo "./$0 rhm-per530-01.rhm.lab.eng.bos.redhat.com pike ipv6" 2>&1
    exit 1
fi

SCENARIO=$3

DATE=$(date +%Y%m%d-%H%M)
SCALEBOX=$1
RELEASE=$2
RESULTRCPT="ansmith@redhat.com"
ROOTDIR="/home/osdeploy/ooo-deploy/"
SCENARIODIR="$ROOTDIR/scenarios/$SCENARIO"
BASEDIR="$ROOTDIR/run/$RELEASE-$SCALEBOX"
LOGDIR="$ROOTDIR/logs/$RELEASE-$SCALEBOX"
SSH="ssh -t -F $BASEDIR/ssh.config.ansible undercloud"
SCP="scp -F $BASEDIR/ssh.config.ansible"
LOGFILE="$LOGDIR/pike-$SCALEBOX.log"

if [ ! -d $SCENARIODIR ]; then
    "Wrong deploy type: $SCENARIO"; exit 1
fi

function ooq_install_undercloud() {
# image downloaded from here: 
# http://209.132.178.27/master/delorean/consistent/stable/undercloud.qcow2
#-e undercloud_image_url="file:///var/cache/tripleo-quickstart/images/undercloud-20170612-stable.qcow2" \
    rm -rf $LOGFILE "$BASEDIR"
    mkdir -p "$BASEDIR" "$LOGDIR"
    pushd $ROOTDIR/tripleo-quickstart
    export OPT_NO_CLONE=1
    export OPT_DEBUG_ANSIBLE=0
    export OPT_SYSTEM_PACKAGES=0
    export SHELL=/bin/bash
    socketdir=$(mktemp -d /tmp/sockXXXXXX)
    export ANSIBLE_SSH_CONTROL_PATH=$socketdir/%%h-%%r
    case "$RELEASE" in
	*osp*)
	    # normalize osp release name
	    RELEASE=$(echo $RELEASE | sed -E 's/(rh)?osp(-)?([0-9]+)/rhos-\3/')
	    # OVERCLOUD_IMG="http://rhos-release.virt.bos.redhat.com/ci-images/$RELEASE/current-passed-ci/overcloud-full.tar"
	    OVERCLOUD_IMG="file:///var/cache/tripleo-quickstart/images/rhosp-13/overcloud-full-13.0-20180126.1.el7ost.x86_64.tar"
            wget http://rhos-release.virt.bos.redhat.com/ci-images/internal-requirements-new.txt
            ./quickstart.sh --working-dir $BASEDIR \
		--requirements requirements.txt  \
		-r internal-requirements-new.txt \
		-X \
		--bootstrap \
		-R $RELEASE \
		-T all \
		-e overcloud_image_url=$OVERCLOUD_IMG \
		--config $SCENARIODIR/oooq-config.yaml \
		--nodes $SCENARIODIR/oooq-nodes.yaml \
		$SCALEBOX 2>&1 | tee $LOGFILE
	    ;;
	*)
            ./quickstart.sh -v --working-dir $BASEDIR \
		--requirements requirements.txt  \
		-p quickstart-extras.yml -r quickstart-extras-requirements.txt \
		-X \
		--bootstrap \
		-R $RELEASE \
		-T all \
		--config $SCENARIODIR/oooq-config.yaml \
		--nodes $SCENARIODIR/oooq-nodes.yaml \
		$SCALEBOX 2>&1 | tee $LOGFILE
    esac
    ret=${PIPESTATUS[0]}
    popd
    
    if [ $ret -ne 0 ]; then
        echo "quickstart.sh on $SCALEBOX failed"
        exit 1
    fi
}

function prepare_playbooks() {
cat > "$BASEDIR/ansible.cfg" <<EOF
[ssh_connection]
ssh_args = -F $BASEDIR/ssh.config.ansible
EOF

cat > "$BASEDIR/ooo_inventory" <<EOF
undercloud
EOF

VARS=$(cat $SCENARIODIR/vars | perl -pi -e 's,^,    ,g')
cat > "$BASEDIR/playbook"<<EOF
---
- hosts: localhost
  gather_facts: no
  vars:
$VARS
  tasks:
    - name: Render deploy-ha script
      template:
        src: ../../deploy-ha.sh.j2
        dest: $BASEDIR/deploy-ha.sh

- hosts: undercloud
  user: stack
  gather_facts: no
  tasks:
    - name: Copy deploy-ha script
      copy:
        src: $BASEDIR/deploy-ha.sh
        dest: /home/stack/deploy-ha.sh
        mode: 0755
    - name: Copy custom yaml files
      copy:
        src: "$SCENARIODIR/{{ item }}"
        dest: "/home/stack/{{ item }}"
      with_items:
        - network-environment.yaml
        - custom_stuff.yaml
    - name: Copy additional files
      copy:
        src: "$SCENARIODIR/{{ item }}"
        dest: "/home/stack/{{ item }}"
      with_items:
        - custom_roles.yaml
      ignore_errors: yes
    - name: Copy scenario-extra files
      copy:
        src: "$SCENARIODIR/{{ item }}"
        dest: "/home/stack/{{ item }}"
        mode: 0755
      with_items: "{{ extra_files|default([]) }}"
      ignore_errors: yes
    - name: Copy nice bashrc to undercloud
      copy:
        src: $ROOTDIR/templates/bashrc
        dest: /home/stack/.bashrc
        mode: 0755
    - name: Run deploy-ha
      shell: >
        ./deploy-ha.sh $RELEASE 2>&1 > /home/stack/deploy_ha.log
    - name: Run extra post scripts
      shell: >
        "{{ item }} 2>&1 > /home/stack/{{ item.log }}"
      with_items: "{{ extra_files|default([]) }}"
      
EOF
} # prepare_playbooks

ooq_install_undercloud
prepare_playbooks
export ANSIBLE_CONFIG="$BASEDIR/ansible.cfg"
ansible-playbook  -i $BASEDIR/ooo_inventory $BASEDIR/playbook

