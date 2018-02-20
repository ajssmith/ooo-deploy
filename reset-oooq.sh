#!/bin/bash
set -eux

function apply_patch() {
  local CHANGE=$1
  local REPO=$2
  local DIR=$3
  # patchset revision is 4th optional argument 
  if [[ -z ${4-} ]]; then
    REF=$(curl -s "https://review.openstack.org/changes/?q=change:$CHANGE&o=CURRENT_REVISION" |tail -n+2|jq -r '.[] | .revisions[.current_revision] | .ref')
  else
    REF=$(curl -s "https://review.openstack.org/changes/?q=change:$CHANGE&o=ALL_REVISIONS" |tail -n+2| jq -r '.[] | .revisions | to_entries | map(select(.value._number=='$4')) | .[0]|.value.ref')
  fi
  echo "Revision for $CHANGE/${4-} -> $REF"
  pushd $DIR
  git config --global user.email "michele@acksyn.org"
  git config --global user.name "Michele Baldessari"
  git fetch https://git.openstack.org/openstack/$REPO $REF && git cherry-pick FETCH_HEAD
  popd
}

# applies review below 4th revision
# apply_patch 474486 tripleo-heat-templates tripleo-heat-templates 4

echo "This removes all tripleo-quickstart-* folders, rechecks stuff out from git and reapplies any patches"

BASEDIR=$(pwd)
if [ $BASEDIR != "/home/ospdeploy/ci/bruce-ha" ]; then
  echo "Run this from $BASEDIR"
  exit 1
fi

rm -rf /tmp/tripleo-quickstart* || /bin/true
mv tripleo-quickstart tripleo-quickstart-extras /tmp || /bin/true

git clone https://github.com/openstack/tripleo-quickstart
git clone https://github.com/openstack/tripleo-quickstart-extras
pushd tripleo-quickstart
#git checkout d98dd74561b2
popd
pushd tripleo-quickstart-extras
#git checkout 465fed252424
popd


# Set the requirements to point to the local git checkout
echo "git+file://$BASEDIR/tripleo-quickstart-extras" > $BASEDIR/tripleo-quickstart/quickstart-extras-requirements.txt

# WIP Initial autofencing support
apply_patch 502297 tripleo-quickstart-extras tripleo-quickstart-extras
# WIP DNR Add undercloud ~/.ssh/config to simplify development 
apply_patch 510332 tripleo-quickstart-extras tripleo-quickstart-extras
# Use --debug in container uploads
#apply_patch 526746 tripleo-quickstart-extras tripleo-quickstart-extras

