#!/bin/bash

CODEBUILD="${1}" #true or false

RDS_INSTANCE="${2}"

echo "Running backup script for RDS instance ${RDS_INSTANCE} using CodeBuild ${CODEBUILD}"

RESTORE_TIME=$(aws rds describe-db-instance-automated-backups --db-instance-identifier "${RDS_INSTANCE}" | jq --raw-output '.DBInstanceAutomatedBackups[].RestoreWindow')
echo "The following is the restore window that can be used:"
echo "RestoreWindow:${RESTORE_TIME}"


if [[ "${CODEBUILD}" == "true" ]]; then

    RESTORE_TO_LATEST="${3}"
    echo "Restore latest backup: ${RESTORE_TO_LATEST}"

    if [[ "${RESTORE_TO_LATEST}" == "false" ]]; then
      POINT_IN_TIME="${4}"
      echo "Point in time to recover: ${POINT_IN_TIME}"
    fi


elif [[ "${CODEBUILD}" == "false" ]]; then

  CONFIRMATION_ANSWER=""

  while [[ "$CONFIRMATION_ANSWER" != "YES" ]]; do
      read -r -p "Do you want to restore the db to the latest restorable time? [YES/NO]: " CONFIRMATION_ANSWER

      if [[ "$CONFIRMATION_ANSWER" == "YES" ]]; then
          RESTORE_TO_LATEST="true"
          break
      elif [[ "$CONFIRMATION_ANSWER" == "NO" ]]; then
          RESTORE_TO_LATEST="false"
          read -r -p "Enter the point in time from which to restore (UTC Time Format as in the Restore Window): " POINT_IN_TIME
          break
      else
        echo "Invalid option. Valid options are YES or NO."
      fi
  done


else
  echo "CODEBUILD variable with invalid value: ${CODEBUILD}"

fi


### Start restore action
RDS_INSTANCE_DETAILS=$(aws rds describe-db-instances --db-instance-identifier "${RDS_INSTANCE}")
DB_INSTANCE_CLASS=$(echo "$RDS_INSTANCE_DETAILS" | jq --raw-output '.DBInstances[].DBInstanceClass')
DB_AVAILABILITY_ZONE=$(echo "$RDS_INSTANCE_DETAILS" | jq --raw-output '.DBInstances[].AvailabilityZone')
DB_SUBNET_GROUP=$(echo "$RDS_INSTANCE_DETAILS" | jq --raw-output '.DBInstances[].DBSubnetGroup.DBSubnetGroupName')
DB_VPC_SECURITY_GROUP=$(echo "$RDS_INSTANCE_DETAILS" | jq --raw-output '.DBInstances[].VpcSecurityGroups[].VpcSecurityGroupId')
DB_PARAMETER_GROUP=$(echo "$RDS_INSTANCE_DETAILS" | jq --raw-output '.DBInstances[].DBParameterGroups[].DBParameterGroupName')
DB_MASTER_USERNAME=$(echo "$RDS_INSTANCE_DETAILS" | jq --raw-output '.DBInstances[].MasterUsername')

if [[ "$RESTORE_TO_LATEST" == "true" ]]; then
  echo "Using latest restorable time to restore database"
  DB_CREATION_COMMAND=$(aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier "${RDS_INSTANCE}" \
    --target-db-instance-identifier "restored-${RDS_INSTANCE}" \
    --use-latest-restorable-time  --db-instance-class "${DB_INSTANCE_CLASS}" --availability-zone "${DB_AVAILABILITY_ZONE}" --db-subnet-group-name "${DB_SUBNET_GROUP}" \
    --no-multi-az --no-publicly-accessible --no-auto-minor-version-upgrade --vpc-security-group-ids "${DB_VPC_SECURITY_GROUP}" \
    --db-parameter-group-name "${DB_PARAMETER_GROUP}" --no-deletion-protection)
  echo "${DB_CREATION_COMMAND}" 

elif [[ "$RESTORE_TO_LATEST" == "false" ]]; then
  
  echo "Using point in time ${POINT_IN_TIME} to restore database"
  DB_CREATION_COMMAND=$(aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier "${RDS_INSTANCE}" \
    --target-db-instance-identifier "restored-${RDS_INSTANCE}" \
    --restore-time "${POINT_IN_TIME}"  --db-instance-class "${DB_INSTANCE_CLASS}" --availability-zone "${DB_AVAILABILITY_ZONE}" --db-subnet-group-name "${DB_SUBNET_GROUP}" \
    --no-multi-az --no-publicly-accessible --no-auto-minor-version-upgrade --vpc-security-group-ids ${DB_VPC_SECURITY_GROUP} \
    --db-parameter-group-name "${DB_PARAMETER_GROUP}" --no-deletion-protection)
else
  echo "ERROR: Invalid value for variable RESTORE_TO_LATEST. Value: ${RESTORE_TO_LATEST}"
  exit 1
fi

DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier "restored-${RDS_INSTANCE}" | jq --raw-output '.DBInstances[].DBInstanceStatus')
while [[ "${DB_STATUS}" != "available"  ]]; do
  echo "Restored DB Status: ${DB_STATUS}. Waiting for db creation..."
  sleep 10
  DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier "restored-${RDS_INSTANCE}" | jq --raw-output '.DBInstances[].DBInstanceStatus')
  if [[ "${DB_STATUS}" == "deleting" ]]; then
    echo "Something happened and DB is being deleted."
    exit 1
  fi
done

echo "DB Status: ${DB_STATUS}"


# Starting db backup
#
# The script dump all MySQL databases in the server. See the "Variables"
# section to check all options. Also, allows uploading the current backup
# to an S3 compatible bucket (the s3cmd or aws command is required for this task).
#
# - Instructions: -
# Copy the script to '/usr/local/sbin/mysqlbackup.sh'
# Add execution permisions: chmod +x /usr/local/sbin/mysqlbackup.sh
#
# - Usage: - 
#  /usr/local/sbin/mysqlbackup.sh
#
# - Cron example: -
# PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# 0 2 * * * root /usr/local/sbin/mysqlbackup.sh >/dev/null 2>&1
#
# **NOTE:** If you set the 'S3TOOL=aws-cli', be sure to include in the above 'PATH'
# variable the aws command location.
#
# By Carlos Bustillo <carlos@speedyrails.com>
#
# Script Version
VERSION="build v1.5 (20200611)"

### Variables ###
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Base backup directory
BASEBKPDIR="/backups/mysql"

# Remove old backups from (-mtime compatible format for the find command)
REMOVEOLDBKPFROM="+5"

# Databases to exclude in the dump
DBSTOEXCLUDE="mysql|information_schema|performance_schema|sys|innodb|tmp"

# Backup users and their grants: YES/NO
# This task will create a file in the '$BASEBKPDIR/users-grants/' directory
BKPUSERGRANTS="NO"

# Storage the current backup in an S3 compatible bucket: YES/NO
STORS3="YES"

# S3 tool to upload the backups: s3cmd/aws-cli
S3TOOL="aws-cli"

# S3 compatible bucket name/prefix
# e.g: my-bucket
#      my-bucket/backups
S3BUCKET="${5}"

# Remove the current backup after upload to an S3 compatible bucket: YES/NO
REMOVEBKP="YES"

# Enable PagerDuty notifications if the backup tasks fails: YES/NO
ENABLE_PG_NOTIFICATIONS="NO"

# Database host
DB_HOST=$(aws rds describe-db-instances --db-instance-identifier "restored-${RDS_INSTANCE}" | jq --raw-output '.DBInstances[].Endpoint.Address')

echo "Building .my.cnf file"
touch .my.cnf
chmod 600 .my.cnf
echo "[client]" >> .my.cnf
echo password="${6}" >> .my.cnf
echo host="$DB_HOST" >> .my.cnf
echo user="$DB_MASTER_USERNAME" >> .my.cnf
cat .my.cnf

# PagerDuty parameters
PG_CREATE_EVENT_URL="https://events.pagerduty.com/generic/2010-04-15/create_event.json"
PG_SERVICE_KEY_FOR_CRITICAL="54fd2e2537864f07b701ee509f4f9e83"
PG_SERVICE_KEY_FOR_WARNING="b1f15be3f2804d0e857de717f93edcba"


### Functions ###

usage () {
    echo "$VERSION"
    echo "
mysqlbackup.sh dump all MySQL databases in the server
Usage: `basename $0`
Options:
    -v           print version number and exit
    -h           prints this help and exit
    "
}

# Parse script options
parse_opts() {

    while getopts "vh" Option; do
        case $Option in
        v) echo "$VERSION"; exit 0;;
        h) usage; exit 0;;
        *) usage; exit 0;;
        esac
    done
}

# Check script requirements
check_requirements() {
    if [ ! -d $BASEBKPDIR ]; then
        mkdir -p "$BASEBKPDIR"
    fi

    if [ ! -d $BASEBKPDIR/users-grants ] && [ $BKPUSERGRANTS == "YES" ]; then
        mkdir -p "$BASEBKPDIR/users-grants/"
    fi

    if [ "$STORS3" == "YES" ] && [ "$S3TOOL" == "s3cmd" ] && [ -z `which s3cmd` ]; then
        echo "The command 's3cmd' is not installed in the system!!"
        echo "Please install using: apt update && apt install python3-pip && pip3 install s3cmd"
        exit 1
    fi

    if [ "$STORS3" == "YES" ] && [ "$S3TOOL" == "aws-cli" ] && [ -z `which aws` ]; then
        echo "The command 'aws-cli' is not installed in the system!!"
        echo "Please install using: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html"
        exit 1
    fi

    if [ -z `which curl` ]; then
        echo "The command 'curl' is not installed in the system!!"
        echo "Please install using: apt install curl"
        exit 1
    fi
}

backup_users_grants() {

    # Get MySQL version in MAJOR.MINOR format
    MYSQL_VERSION=`mysql -e "SHOW VARIABLES LIKE 'version';" | grep version | awk '{print $2}' | awk -F. '{print $1 "." $2}'`

    # Variable for control errors
    ERROR_TASK="0"

    if [ "$MYSQL_VERSION" == "5.5" ] || [ "$MYSQL_VERSION" == "5.6" ]; then
        # Export users and their grants
        mysql -B -N -e "SELECT DISTINCT CONCAT('SHOW GRANTS FOR \'', user, '\'@\'', host, '\';') AS query FROM mysql.user WHERE user != 'debian-sys-maint' AND user != 'root' AND user != 'phpmyadmin' AND user != 'mysql.sys' AND user != 'mysql.session' AND user != 'mysql.infoschema'" \
        | mysql | sed 's/\(GRANT .*\)/\1;/;s/^\(Grants for .*\)/## \1 ##/;/##/{x;p;x;}'\
        > $BASEBKPDIR/users-grants/users-$(date +%y-%m-%d).sql

        if [ "$?" != "0" ] && [ "$ENABLE_PG_NOTIFICATIONS" == "YES" ]; then
            send_alert "The task to export the MySQL users and their grants has been failed"
            ERROR_TASK="1"
        fi

    elif [ "$MYSQL_VERSION" == "5.7" ]; then
        # Export users
        mysql -B -N -e "SELECT DISTINCT CONCAT('SHOW CREATE USER \'', user, '\'@\'', host, '\';') AS query FROM mysql.user WHERE user != 'debian-sys-maint' AND user != 'root' AND user != 'phpmyadmin' AND user != 'mysql.sys' AND user != 'mysql.session' AND user != 'mysql.infoschema'" \
        | mysql | sed 's/\(CREATE .*\)/\1;/;s/^\(CREATE USER for .*\)/## \1 ##/;/##/{x;p;x;}' \
        > $BASEBKPDIR/users-grants/users-$(date +%y-%m-%d).sql

        if [ "$?" != "0" ] && [ "$ENABLE_PG_NOTIFICATIONS" == "YES" ]; then
            send_alert "The task to export the MySQL users has been failed"
            ERROR_TASK="1"
        fi

        # Export users's grants
        mysql -B -N -e "SELECT DISTINCT CONCAT('SHOW GRANTS FOR \'', user, '\'@\'', host, '\';') AS query FROM mysql.user WHERE user != 'debian-sys-maint' AND user != 'root' AND user != 'phpmyadmin' AND user != 'mysql.sys' AND user != 'mysql.session' AND user != 'mysql.infoschema'" \
        | mysql | sed 's/\(GRANT .*\)/\1;/;s/^\(Grants for .*\)/## \1 ##/;/##/{x;p;x;}' \
        >> $BASEBKPDIR/users-grants/users-$(date +%y-%m-%d).sql

        if [ "$?" != "0" ] && [ "$ENABLE_PG_NOTIFICATIONS" == "YES" ]; then
            send_alert "The task to export the MySQL users grants has been failed"
            ERROR_TASK="1"
        fi

    elif [ "$MYSQL_VERSION" == "8.0" ]; then
        # Export user table form mysql DB
        mysqldump mysql user > $BASEBKPDIR/users-grants/users-$(date +%y-%m-%d).sql

        if [ "$?" != "0" ] && [ "$ENABLE_PG_NOTIFICATIONS" == "YES" ]; then
            send_alert "The task to export the MySQL user table has been failed"
            ERROR_TASK="1"
        fi
    fi

    # Put the exported file in an S3 compatible bucket
    if [ "$STORS3" == "YES" ] && [ "$ERROR_TASK" == "0" ]; then
        if [ "$S3TOOL" == "s3cmd" ]; then
            s3cmd put "$BASEBKPDIR/users-grants/users-$(date +%y-%m-%d).sql" s3://$S3BUCKET/users-grants/

            if [ "$?" != "0" ] && [ "$ENABLE_PG_NOTIFICATIONS" == "YES" ]; then
                send_alert "The copy of MySQL users grants to S3 compatible bucket has been failed"
            fi
        fi
        
        if [ "$S3TOOL" == "aws-cli" ] && [ "$ERROR_TASK" == "0" ]; then
            aws s3 cp "$BASEBKPDIR/users-grants/users-$(date +%y-%m-%d).sql" s3://$S3BUCKET/users-grants/

            if [ "$?" != "0" ] && [ "$ENABLE_PG_NOTIFICATIONS" == "YES" ]; then
                send_alert "The copy of MySQL users grants to S3 compatible bucket has been failed"
            fi
        fi
        
        if [ "$REMOVEBKP" == "YES" ] && [ "$ERROR_TASK" == "0" ]; then
            rm -f "$BASEBKPDIR/users-grants/users-$(date +%y-%m-%d).sql"
        fi
    fi
}

# Send alert to PagerDuty if any backup tasks fails
send_alert() {

    SERVER_IP_ADDR=`ip addr | grep eth0 | grep inet | awk '{print $2}' | sed 's/\/24//g'`
    SERVER_HOSTNAME=`hostname -f`

    PG_TEXT_ERROR="$1"
    PG_EVENT_TYPE="trigger"
    PG_INCIDENT_KEY="BACKUP FAILED $SERVER_HOSTNAME"
    PG_SERVICE_KEY="${PG_SERVICE_KEY_FOR_CRITICAL}"

    # echo "Some backup task has been failed in the server $(hostname -f) ($SERVER_IP_ADDR)"
    curl --silent --output /dev/null -X POST -d "{\"service_key\":\"$PG_SERVICE_KEY\",\"incident_key\":\"$PG_INCIDENT_KEY\",\"event_type\":\"$PG_EVENT_TYPE\",\"description\":\"$PG_TEXT_ERROR on $SERVER_HOSTNAME($SERVER_IP_ADDR)\"}" \
    $PG_CREATE_EVENT_URL

}

### Main Program ###

# Parse script options
parse_opts $@

# Check script requirements
check_requirements

# Backup all users and their grants in a .sql file
if [ $BKPUSERGRANTS == "YES" ]; then
    backup_users_grants
fi

# Get all databases name
DBS=`mysql --host="$DB_HOST" --user="$DB_MASTER_USERNAME" --password="${6}" -e "show databases;" | egrep -v "Database|$DBSTOEXCLUDE"`

if [ ! -z "$DBS" ]; then
    # Dump each gotten database
    for DB in $DBS; do

        # Create the database base directory to storage the backups
        if [ ! -d $BASEBKPDIR/$DB/ ]; then
            mkdir -p $BASEBKPDIR/$DB
        fi

        # Dump MySQL databases
        mysqldump \
            --add-drop-table \
            --add-locks \
            --create-options \
            --disable-keys \
            --extended-insert \
            --quick \
            --set-charset \
            --user=$DB_MASTER_USERNAME \
            --host=$DB_HOST \
            --password=${6} \
            "$DB" | gzip >"$BASEBKPDIR/$DB/$(date +%y-%m-%d).sql.gz" 

        if [ "${PIPESTATUS[0]}" != "0" ] && [ "$ENABLE_PG_NOTIFICATIONS" == "YES" ]; then
            send_alert "The dump for $DB database has been failed"
            continue
        fi

        # Put the current backup in an S3 compatible bucket
        if [ "$STORS3" == "YES" ]; then
            if [ "$S3TOOL" == "s3cmd" ]; then
                s3cmd put "$BASEBKPDIR/$DB/$(date +%y-%m-%d).sql.gz" s3://$S3BUCKET/$DB/

                if [ "$?" != "0" ] && [ "$ENABLE_PG_NOTIFICATIONS" == "YES" ]; then
                    send_alert "The copy $DB database to S3 compatible bucket has been failed"
                fi
            fi

            if [ "$S3TOOL" == "aws-cli" ]; then
                aws s3 cp "$BASEBKPDIR/$DB/$(date +%y-%m-%d).sql.gz" s3://$S3BUCKET/$DB/

                if [ "$?" != "0" ] && [ "$ENABLE_PG_NOTIFICATIONS" == "YES" ]; then
                    send_alert "The copy $DB database to S3 compatible bucket has been failed"
                fi
            fi

            if [ "$REMOVEBKP" == "YES" ]; then
                rm -f "$BASEBKPDIR/$DB/$(date +%y-%m-%d).sql.gz"
            fi
        fi
    done
fi

# Remove old backup files
find "$BASEBKPDIR" -type f -mtime $REMOVEOLDBKPFROM -print0 | xargs -r0 rm -f

echo "DB dumps sent to S3"

echo "Starting deletion of RDS instance: restored-${RDS_INSTANCE}"

aws rds delete-db-instance --db-instance-identifier "restored-${RDS_INSTANCE}" --skip-final-snapshot || exit 1

DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier "restored-${RDS_INSTANCE}" | jq --raw-output '.DBInstances[].DBInstanceStatus')
while [[ "${DB_STATUS}" == "deleting"  ]]; do
  echo "Restored DB Status: ${DB_STATUS}. Waiting for db deletion..."
  sleep 10
  DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier "restored-${RDS_INSTANCE}" | jq --raw-output '.DBInstances[].DBInstanceStatus')
done

echo "Restored RDS instance deleted"

exit 0
