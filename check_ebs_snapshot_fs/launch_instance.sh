#!/bin/bash
#
# launch_instance.sh
#
#####################################################################

set -o pipefail

#######################################
# flow control for debugging
#######################################
SKIP_DELETE_INSTANCE=0
SKIP_ECHO_MESSAGE=0

#######################################
# default configuration
#######################################
INSTANCE_NAME="fs-check-tmp"
AMI_ID="ami-011facbea5ec0363b"
SUBNET_ID="subnet-050192cb68d5172f4"
KEY_PAIR_NAME="ks-aws"
SECURITY_GROUP_ID="sg-0fdfac540fc17980a"
PROFILE_NAME="check_ebs_fs_profile"
USER_DATA="file://check_ebs_snapshot_fs.sh"
LOGFILE_PATH="/var/log/launch_instance.log"
SUDO=""

#######################################
# time spent
#######################################
function time_spent() {
	hrs=$(( SECONDS/3600 ))
	mins=$(( (SECONDS-hrs*3600)/60))
	secs=$(( SECONDS-hrs*3600-mins*60 ))
	TM=$(printf '%02d:%02d\n' $mins $secs)
}

#######################################
# time echo
#######################################
function time_echo() {
	time_spent
	if [ $SKIP_ECHO_MESSAGE == 0 ]; then
		echo "$TM $1" | $SUDO tee -a $LOGFILE_PATH
	fi
}

#######################################
# main
#######################################

trap 'echo "ERROR: line no = $LINENO, exit status = $?" >&2; exit 1' ERR

time_echo "$0 starting..."
INSTANCE_ID=$(aws ec2 run-instances \
	--image-id="$AMI_ID" \
	--subnet-id="$SUBNET_ID" \
	--key-name="$KEY_PAIR_NAME" \
	--security-group-ids="$SECURITY_GROUP_ID" \
	--user-data="$USER_DATA" \
	--instance-type=t2.micro \
	--iam-instance-profile="Name=$PROFILE_NAME" \
	--output text \
	--tag-specifications="ResourceType=instance,Tags=[{Key=Name,Value=fs-check-tmp}]" \
	--query "Instances[*].{Instance:InstanceId}")

time_echo "Instance id:$INSTANCE_ID"

time_echo "Instance($INSTANCE_ID) waiting for running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

time_echo "Instance($INSTANCE_ID) waiting for stopping..."
aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID

if [ $SKIP_DELETE_INSTANCE == 0 ]; then
	time_echo "Instance($INSTANCE_ID) being terminated..."
	aws ec2 terminate-instances --instance-ids $INSTANCE_ID
	aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
	time_echo "Instance($INSTANCE_ID) terminated"
else
	time_echo "Instance($INSTANCE_ID) skipped termination"
fi
time_echo "$0 done"

exit 0
