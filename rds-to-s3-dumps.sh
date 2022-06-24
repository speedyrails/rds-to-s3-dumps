#!/bin/bash

CODEBUILD="${1}" #true or false

RDS_INSTANCE="${2}"

echo -e "Running backup script for RDS instance ${RDS_INSTANCE} using CodeBuild ${CODEBUILD}"

RESTORE_TIME=$(aws rds describe-db-instance-automated-backups --db-instance-identifier ${RDS_INSTANCE} | jq --raw-output '.DBInstanceAutomatedBackups[].RestoreWindow')
echo -e "\nThe following is the restore window that can be used:\n"
echo -e "RestoreWindow:\n${RESTORE_TIME}"


if [[ "${CODEBUILD}" == "true" ]]; then

    RESTORE_TO_LATEST=${3}
    echo -e "Restore latest backup: ${RESTORE_TO_LATEST}"

    if [[ "${RESTORE_TO_LATEST}" == "false" ]]; then
      POINT_IN_TIME=${4}
      echo -e "Point in time to recover: ${POINT_IN_TIME}"
    fi


elif [[ "${CODEBUILD}" == "false" ]]; then

  CONFIRMATION_ANSWER=""

  while [[ "$CONFIRMATION_ANSWER" != "YES" ]]; do
      read -r -p "Do you want to restore the db to the latest restorable time? [YES/NO]: " CONFIRMATION_ANSWER

      if [ "$CONFIRMATION_ANSWER" == "YES" ]; then
          RESTORE_TO_LATEST="true"
          break
      elif [ "$CONFIRMATION_ANSWER" == "NO" ]; then
          RESTORE_TO_LATEST="false"
          break
      else
        echo -e "Invalid option. Valid options are YES or NO."
      fi
  done



else
  echo -e "CODEBUILD variable with invalid value: ${CODEBUILD}"

fi


### Start restore action
RDS_INSTANCE_DETAILS=$(aws rds describe-db-instances --db-instance-identifier ${RDS_INSTANCE})
DB_INSTANCE_CLASS=$(echo $RDS_INSTANCE_DETAILS | jq --raw-output '.DBInstances[].DBInstanceClass')
DB_AVAILABILITY_ZONE=$(echo $RDS_INSTANCE_DETAILS | jq --raw-output '.DBInstances[].AvailabilityZone')
DB_SUBNET_GROUP=$(echo $RDS_INSTANCE_DETAILS | jq --raw-output '.DBInstances[].DBSubnetGroup.DBSubnetGroupName')
DB_VPC_SECURITY_GROUP=$(echo $RDS_INSTANCE_DETAILS | jq --raw-output '.DBInstances[].VpcSecurityGroups[].VpcSecurityGroupId')
DB_PARAMETER_GROUP=$(echo $RDS_INSTANCE_DETAILS | jq --raw-output '.DBInstances[].DBParameterGroups[].DBParameterGroupName')

#echo -e "class: ${DB_INSTANCE_CLASS}, zone: ${DB_AVAILABILITY_ZONE}, subnet_group: ${DB_SUBNET_GROUP}, SG: ${DB_VPC_SECURITY_GROUP}, parameter_group: ${DB_PARAMETER_GROUP}"

#exit 1
if [ "$RESTORE_TO_LATEST" == "true" ]; then
  echo -e "Using latest restorable time to restore database"
  DB_CREATION_COMMAND=$(aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier ${RDS_INSTANCE} \
    --target-db-instance-identifier restored-${RDS_INSTANCE} \
    --use-latest-restorable-time  --db-instance-class ${DB_INSTANCE_CLASS} --availability-zone ${DB_AVAILABILITY_ZONE} --db-subnet-group-name ${DB_SUBNET_GROUP} \
    --no-multi-az --no-publicly-accessible --no-auto-minor-version-upgrade --vpc-security-group-ids ${DB_VPC_SECURITY_GROUP} \
    --db-parameter-group-name ${DB_PARAMETER_GROUP} --no-deletion-protection)
  echo -e "\n${DB_CREATION_COMMAND}\n" 

elif [ "$RESTORE_TO_LATEST" == "false" ]; then
  read -r -p "Enter the point in time from which to restore (UTC Time Format as in the Restore Window): " POINT_IN_TIME
  echo -e "Using point in time ${POINT_IN_TIME} to restore database"
  DB_CREATION_COMMAND=$(aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier ${RDS_INSTANCE} \
    --target-db-instance-identifier restored-${RDS_INSTANCE} \
    --restore-time ${POINT_IN_TIME}  --db-instance-class ${DB_INSTANCE_CLASS} --availability-zone ${DB_AVAILABILITY_ZONE} --db-subnet-group-name ${DB_SUBNET_GROUP} \
    --no-multi-az --no-publicly-accessible --no-auto-minor-version-upgrade --vpc-security-group-ids ${DB_VPC_SECURITY_GROUP} \
    --db-parameter-group-name ${DB_PARAMETER_GROUP} --no-deletion-protection)
else
  echo -e "ERROR: Invalid value for variable RESTORE_TO_LATEST. Value: ${RESTORE_TO_LATEST}"
  exit 1
fi

DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier restored-${RDS_INSTANCE} | jq --raw-output '.DBInstances[].DBInstanceStatus')
while [[ "${DB_STATUS}" != "available"  ]]; do
  echo -e "Restored DB Status: ${DB_STATUS}. Waiting for db creation..."
  sleep 10
  DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier restored-${RDS_INSTANCE} | jq --raw-output '.DBInstances[].DBInstanceStatus')
  if [[ "${DB_STATUS}" == "deleting" ]]; then
    echo -e "Something happened and DB is being deleted."
    exit 1
  fi
done

echo -e "DB Status: ${DB_STATUS}"