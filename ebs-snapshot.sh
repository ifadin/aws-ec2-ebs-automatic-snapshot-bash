#!/usr/bin/env bash

export PATH=$PATH:/usr/local/bin/:/usr/bin

# Safety feature: exit script if error is returned, or if variables not set.
# Exit if a pipeline results in an error.
set -ue
set -o pipefail



## Automatic EBS Volume Snapshot Creation & Clean-Up Script

# Forked from https://github.com/CaseyLabs/aws-ec2-ebs-automatic-snapshot-bash
#
# PURPOSE: This Bash script can be used to take automatic snapshots of your Linux EC2 instance. Script process:
# - Determine the instance ID of the EC2 server on which the script runs
# - Gather a list of all volume IDs attached to that instance
# - Take a snapshot of each attached volume
# - The script will then delete all associated snapshots taken by the script that are older than 7 days
#
# DISCLAIMER: This script deletes snapshots (though only the ones that it creates).


## Variable Declarations ##

# Get Instance Details
readonly EC2_META_API="169.254.169.254"
readonly INSTANCE_ID=$(wget -q -O- http://"$EC2_META_API"/latest/meta-data/instance-id)
readonly REGION=$(wget -q -O- http://"$EC2_META_API"/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g')

# Set Logging Options
readonly SCRIPT_NAME="${0##*/}"
readonly LOGFILE="${BACKUP_LOG:-/var/log/ebs-backup.log}"
declare -r -i LOGFILE_MAX_LINES="5000"

# How many days do you wish to retain backups for? Default: 30 days
declare -r -i RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
declare -r -i RETENTION_DAYS_IN_SECONDS=$(date +%s --date="$RETENTION_DAYS days ago")


## Function Declarations ##

# Function: Setup logfile and redirect stdout/stderr.
setup_logging() {
    local -r __logfile=$1
    local -r -i __max_lines=$2

    # Check if logfile exists and is writable.
    ( [ -e "$__logfile" ] || touch "$__logfile" ) && [ ! -w "$__logfile" ] && echo "ERROR: Cannot write to $__logfile. Check permissions or sudo access." && exit 1

    local tmplog=$(tail -n "$__max_lines" "$__logfile" 2>/dev/null) && echo "$tmplog" > "$__logfile"
    exec > >(tee -a "$__logfile")
    exec 2>&1
}

# Function: Log an event.
log() {
    echo "[$(date +"%Y-%m-%d"+"%T") $SCRIPT_NAME]: $*"
}

# Function: Confirm that the AWS CLI and related tools are installed.
check_dependencies() {
	for dep in aws wget; do
		hash "$dep" &> /dev/null
		if [[ $? == 1 ]]; then
			echo "In order to use this script, the executable \"$dep\" must be installed." 1>&2; exit 70
		fi
	done
}

# Function: Snapshot all volumes attached to this instance.
snapshot_volumes() {
    local -r -a __volumes=("$1")
    local -r backup_date="$(date +%Y-%m-%d)"

	for vol_id in "${__volumes[@]}"; do
		log "Volume ID is $vol_id"

		# Get the attached device name to add to the description so we can easily tell which volume this is.
		local volume_name=$(aws ec2 describe-volumes --region "$REGION" --output=text \
		    --volume-ids "$vol_id" --query 'Volumes[0].Tags[?Key==`Name`].Value|[0]')
		local device_name=$(aws ec2 describe-volumes --region "$REGION" --output=text \
		    --volume-ids "$vol_id" --query 'Volumes[0].{Devices:Attachments[0].Device}')

		# Take a snapshot of the current volume, and capture the resulting snapshot ID
		local snapshot_name="$volume_name"
		local snapshot_description="$volume_name ($device_name) backup $backup_date"

		local snapshot_id=$(aws ec2 create-snapshot --region "$REGION" --output=text \
		    --description "$snapshot_description" --volume-id "$vol_id" --query SnapshotId)
		log "New snapshot is $snapshot_id"

		# Add a "CreatedBy:AutomatedBackup" tag to the resulting snapshot.
		# We want to purge only snapshots taken by the script.
		aws ec2 create-tags --region "$REGION" --resource "$snapshot_id" \
		    --tags Key=CreatedBy,Value=AutomatedBackup Key=Name,Value="$snapshot_name"
	done
}

# Function: Cleanup all snapshots associated with this instance that are older than retention period
cleanup_snapshots() {
    local -r -a __volumes=("$1")

	for vol_id in "${__volumes[@]}"; do
		local -a snapshot_list=$(aws ec2 describe-snapshots --region "$REGION" --output=text \
		    --filters "Name=volume-id,Values=$vol_id" "Name=tag:CreatedBy,Values=AutomatedBackup" \
		    --query Snapshots[].SnapshotId)

		for snapshot in ${snapshot_list}; do
			log "Checking $snapshot..."

			# Check age of snapshot
			local snapshot_date=$(aws ec2 describe-snapshots --region "$REGION" --output=text \
			    --snapshot-ids "$snapshot" --query Snapshots[].StartTime)
			local -i snapshot_date_in_seconds=$(date +%s --date="$snapshot_date")
			local snapshot_description=$(aws ec2 describe-snapshots --region "$REGION" --output=text \
			    --snapshot-ids "$snapshot" --query Snapshots[].Description)

			if (( $snapshot_date_in_seconds <= $RETENTION_DAYS_IN_SECONDS )); then
				log "DELETING snapshot $snapshot ($snapshot_description) ..."
				aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snapshot"
			else
				log "Keeping snapshot $snapshot ($snapshot_description)."
			fi
		done
	done
}


## SCRIPT EXECUTION ##

check_dependencies
setup_logging "${LOGFILE}" "${LOGFILE_MAX_LINES}"

# Volumes that are attached to this instance and have tag "Name"
declare -r -a volume_list=("$(aws ec2 describe-volumes --region "$REGION" --output text \
    --filters Name=attachment.instance-id,Values="$INSTANCE_ID" Name=tag-key,Values="Name" --query Volumes[].VolumeId)")

snapshot_volumes "$volume_list"
cleanup_snapshots "$volume_list"
