#!/bin/bash

#! /bin/bash

set -e
if [[ -z "${BACKUP_TAR}" || -z "${BACKUP_DB_URL} " ]]; then
  exit 0
fi

log() {
  message=$1
  ts="$(date +'%Y-%m-%dT%H.%M.%S%z')"
  echo "${ts}: ${message}"
}

cd /tmp
BACKUP_NAME="${BACKUP_TAR%%.tar.gz}"
log "Downloading ${BACKUP_DB_URL}/${BACKUP_TAR}"
wget "${BACKUP_DB_URL}/${BACKUP_TAR}"
log "Extracting backups from tar file ${BACKUP_TAR}"
tar -xf "${BACKUP_TAR}" --directory /tmp --skip-old-files
rm -f ${BACKUP_TAR}

PUPPET_BIN='/opt/puppetlabs/bin'

# Omitting pe-activity, pe-rbac, pe-classifier, pe-orchestrator
DBS=("pe-puppetdb")

SERVICES_THAT_MIGRATE=(
"pe-puppetdb"
"pe-console-services"
"pe-orchestration-services"
)
SERVICES=("${SERVICES_THAT_MIGRATE[@]}")
SERVICES+=(
"pe-puppetserver"
"pe-nginx"
)

for SERVICE in "${SERVICES[@]}"; do
  log "Stopping ${SERVICE}"
  "${PUPPET_BIN}/puppet" resource service $SERVICE ensure=stopped >/dev/null
done

log "Stopping puppet to avoid puppet runs restarting services during restore"
"${PUPPET_BIN}/puppet" resource service puppet ensure=stopped >/dev/null

UPDATETIME_SQL="
DROP TABLE IF EXISTS max_report;

SELECT max(producer_timestamp)
INTO TEMPORARY TABLE max_report
FROM reports;

DROP TABLE IF EXISTS max_resource_event;

SELECT max(timestamp)
INTO TEMPORARY TABLE max_resource_event
FROM resource_events;

DROP TABLE IF EXISTS time_diff;

SELECT (DATE_PART('day', now() - (select max from max_report)) * 24 +
        DATE_PART('hour', now() - (select max from max_report))) * 60 +
        DATE_PART('minute', now() - (select max from max_report)) as minute_diff
INTO TEMPORARY TABLE time_diff;

DROP TABLE IF EXISTS resource_events_time_diff;

SELECT (DATE_PART('day', now() - (select max from max_resource_event)) * 24 +
        DATE_PART('hour', now() - (select max from max_resource_event))) * 60 +
        DATE_PART('minute', now() - (select max from max_resource_event)) as minute_diff
INTO TEMPORARY TABLE resource_events_time_diff;

UPDATE reports
  SET producer_timestamp = producer_timestamp + ((select minute_diff from time_diff) * INTERVAL '1 minute'),
  start_time = start_time + ((select minute_diff from time_diff) * INTERVAL '1 minute'),
  end_time = end_time + ((select minute_diff from time_diff) * INTERVAL '1 minute'),
  receive_time = receive_time + ((select minute_diff from time_diff) * INTERVAL '1 minute');

UPDATE resource_events
  SET timestamp = timestamp + ((select minute_diff from resource_events_time_diff) * INTERVAL '1 minute');

UPDATE catalogs
  SET producer_timestamp = producer_timestamp + ((select minute_diff from time_diff) * INTERVAL '1 minute'),
  timestamp = timestamp + ((select minute_diff from time_diff) * INTERVAL '1 minute');

UPDATE factsets
  SET producer_timestamp = producer_timestamp + ((select minute_diff from time_diff) * INTERVAL '1 minute'),
  timestamp = timestamp + ((select minute_diff from time_diff) * INTERVAL '1 minute');

DROP TABLE IF EXISTS time_diff;
DROP TABLE IF EXISTS max_report;
DROP TABLE IF EXISTS resource_events_time_diff;
DROP TABLE IF EXISTS max_resource_event;
"

PG_SCRIPT="
log() {
  message=\$1
  ts=\"\$(date +'%Y-%m-%dT%H.%M.%S%z')\"
  echo \"\${ts}: \${message}\"
}

for DB in \"${DBS[@]}\"; do
  log \"Restoring \${DB}\"
  /opt/puppetlabs/server/bin/pg_restore -U pe-postgres --if-exists -cCd template1 /tmp/$BACKUP_NAME/\${DB}.backup
done

if [[ \"${DBS[*]}\" =~ pe-puppetdb ]]; then 
  log \"Updating pe-puppetdb times\"
  /opt/puppetlabs/server/bin/psql -d pe-puppetdb -a -c \"${UPDATETIME_SQL}\"
fi
"
su - pe-postgres -s /bin/bash -c "${PG_SCRIPT}"

for SERVICE in "${SERVICES[@]}"; do
  log "Restarting ${SERVICE}"
  if [[ "${SERVICES_THAT_MIGRATE[*]}" =~ "${SERVICE}" ]]; then
    echo ' * service restart will perform database migrations if backup was from an older version of PE' 
  fi
  "${PUPPET_BIN}/puppet" resource service $SERVICE ensure=running >/dev/null
done

if [[ "${DBS[*]}" =~ pe-classifier ]]; then
  log "Running MEEP to reconfigure master classification in pe-classifier" 
  puppet infrastructure configure
fi
log "Running puppet to register master in pe-puppetdb"
"${PUPPET_BIN}/puppet" agent -t 
log "Running puppet to recongigure master based on its presence in pe-puppetdb" 
"${PUPPET_BIN}/puppet" agent -t
log "Running puppet to validate we are steady-state"
"${PUPPET_BIN}/puppet" agent -t || (echo 'Still seeing changes!' && exit 2)

log "Complete"
echo "If you want the puppet daemon started again run:"
echo "${PUPPET_BIN}/puppet resource service puppet ensure=running"
