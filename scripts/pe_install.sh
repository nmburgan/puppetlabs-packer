#!/bin/bash

set -e

PUPPET_BIN='/opt/puppetlabs/bin'

# Read LATEST file to grab the latest build from the directory
if [ -z "${PE_VERSION}" ]; then
  VERSION=$(curl ${PE_TARBALL_URL}/LATEST | tr -d '\n')
else
  VERSION=$PE_VERSION
fi
EXT='.tar'
NAME="puppet-enterprise-${VERSION}-${PLATFORM}"
TARBALL="${NAME}${EXT}"
FULL_TARBALL_URL="${PE_TARBALL_URL}/${TARBALL}"

cd /tmp
wget ${FULL_TARBALL_URL}
tar -xf ${TARBALL}
rm -f ${TARBALL}

# Set up pe.conf
# This is currently what beaker sets up by default. One of these days, we should
# probably just get beaker to do the install rather than do it from this script.
# Note, we are not including the puppet_master_host value here, since it is
# not required for a monolithic install and will need to change anyway for
# each new VM created off this image.
cat << EOF > /tmp/pe.conf
{
  "puppet_enterprise::puppet_master_host": "%{::trusted.certname}"
  "console_admin_password": "puppetlabs",
  "puppet_enterprise::master::recover_configuration::recover_configuration_interval": 0,
  "pe_repo::enable_windows_bulk_pluginsync": true,
  "meep_schema_version": "1.0",
  "puppet_enterprise::profile::puppetdb::node_ttl": "0s",
  "puppet_enterprise::profile::puppetdb::report_ttl": "0s",
  "puppet_enterprise::profile::puppetdb::resource_events_ttl": "0s"
}
EOF

./${NAME}/puppet-enterprise-installer -y -c /tmp/pe.conf
"${PUPPET_BIN}/puppet" agent -t
"${PUPPET_BIN}/puppet" agent -t