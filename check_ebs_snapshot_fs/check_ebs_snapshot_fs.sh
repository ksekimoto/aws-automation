#!/bin/bash
#
# check_snapshot_fs
#   if there is the specified snapshot id, the snapshot id is used.
#   if "TAG" is specified, the snapshot id with the specified tag is used.
#   restore a volume from a snapshot with a tag (fs_check:need),
#   attach the volume to and the specified EC2 instance
#   check file system integrity on the EC2 instance
#   detach the volume from the EC2 instance
#   delete the volume
#   update the tag with the result(ok, ng, or not_supported)
#
# $1: snapshot id
# $2: volume size for restored snapshot (optional)
# 
# pre-requisite
# - Amazon Linux EC2 instance which checks the restored volume
#   set instance id to INSTACNCE_ID environment variable
# - The target snapshot needs to have a tag (fs_check:need)
# - executed by root (no sudo)
#
# How to use
# 1. launch an EC2 instance and get the instance id
# 2. set the instance id to INSTANCE_ID in this script
# 3. add a tag (check_fs:need) to a target snapshot to be checked
# 4. execute this script with "TAG" argument
#    ex. ./check_snapshot_fs.sh TAG
#
# [ec2-user@ip-172-31-39-62 linux]$ ./check_snapshot_fs.sh TAG
# 00:00 trying to find snapshot fs_check:need
# 00:00 volume size is not provided. using default vale.
# 00:01 snapshot(fs_check:need) was found as snap-02e7bed99046c677e
# 00:01 creating volume from snapshot(snap-02e7bed99046c677e)
# 00:19 volume(vol-05f5ef4c0f5aff4ab) created
# 00:19 volume(vol-05f5ef4c0f5aff4ab) attaching..
# 00:23 volume(vol-05f5ef4c0f5aff4ab) attached
# 00:23 file system(ext4) ==> ok
# 00:23 fsck from util-linux 2.23.2
# /: clean, 38210/524288 files, 337099/2096635 blocks
# 00:23 volume(vol-05f5ef4c0f5aff4ab) detaching...
# 00:42 volume(vol-05f5ef4c0f5aff4ab) detached
# 00:42 volume(vol-05f5ef4c0f5aff4ab) deleting...
# 00:45 volume(vol-05f5ef4c0f5aff4ab) deleted
# 00:46 snapshot(snap-02e7bed99046c677e) taggged as fs_check:ok
#####################################################################

set -o pipefail

#######################################
# flow control for debugging
#######################################
SKIP_ECHO_MESSAGE=0
SKIP_CREATE_VOLUME=0
SKIP_ATTACH_VOLUME=0
SKIP_DETACH_VOLUME=0
SKIP_DELETE_VOLUME=0
SKIP_SNS_PUBLISH=1
SHUTDOWN_AT_END=1
SHUTDOWN_TIMEOUT=3

#######################################
# default configurations
#######################################
REGION="ap-northeast-1"
AZ="ap-northeast-1a"
DEVICE="/dev/sdb"
CHECK_DEVICE="/dev/sdb1"
VOL_ID=$DEFAULT_VOL_ID
MOUNT_POINT="/mnt"
SNS_TOPIC_ARN="arn:aws:sns:ap-northeast-1:876160884475:ks-check-ebs-snapshot"
LOGFILE_PATH="/var/log/check_ebs_snapshot_fs.log"
SUDO=""

######################################
# tags
######################################
SP_TAG_KEY="fs_check"
SP_TAG_VALUE_NEED="need"
SP_TAG_VALUE_DONE="done"

SECONDS=0

trap 'echo "ERROR: line no = $LINENO, exit status = $?" >&2; exit 1' ERR

#block device cache cleared
$SUDO blkid -c /dev/null > /dev/null

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
# get instance id
#######################################
function get_instance_id() {
	INSTANCE_ID=$(curl 169.254.169.254/latest/meta-data/instance-id/)
}

#######################################
# create EBS volume from EBS snapshot
# $1: snapshot id
#######################################
function create_EBS_volume() {
	VOL_ID=$(aws ec2 create-volume --region $REGION --availability-zone $AZ --snapshot-id $1 $VOL_PARAM --query VolumeId --output text)
	sleep 2
	aws ec2 wait volume-available --region $REGION --volume-ids $VOL_ID > /dev/null 
}

#######################################
# attach EBS volume
# $1: instance id
# $2: volume id
#######################################
function attach_EBS_volume() {
	aws ec2 attach-volume --region $REGION --device $DEVICE --instance-id $1 --volume-id $2 > /dev/null
	aws ec2 wait volume-in-use --region $REGION --volume-ids $2
	sleep 2
}

#######################################
# detach EBS volume
# $1: volume id
#######################################
function detach_EBS_volume() {
	aws ec2 detach-volume --region $REGION --volume-id $1 > /dev/null
	aws ec2 wait volume-available --region $REGION --volume-ids $1
	sleep 2
}

#######################################
# delete EBS volume
# $1: volume id
#######################################
function delete_EBS_volume() {
	aws ec2 delete-volume --region $REGION --volume-id $1 > /dev/null
	aws ec2 wait volume-deleted --region $REGION --volume-ids $1
	sleep 2 
}

#######################################
# check file system
# $1: device name
#######################################
function check_file_system() {
	FS=$($SUDO blkid $1 | gawk '{print gensub(/^(.+)TYPE=\"(.*)\"/, "\\2", "g")}')
	FS=${FS:0:4}
	case $FS in
	"ntfs" )
		# ntfsfix is included in ntfsprogs or ntfs-3g package
		CHECK_FS_MSG=$($SUDO ntfsfix -n $1 >&1)
		if [ `echo $CHECK_FS_MSG | grep "processed successfully" ` ]; then
			CHECK_FS="ok"
		else
			CHECK_FS="ng"
		fi
		;;
	"ext3" )
		CHECK_FS_MSG=$($SUDO fsck -n $1 2>/dev/null >&1)
		echo $CHECK_FS_MSG | grep "clean" >/dev/null 2>&1
		if [ $? = 0 ]; then
			CHECK_FS="ok"
		else
			CHECK_FS="ng"
		fi
		;;
	"ext4" ) 
		CHECK_FS_MSG=$($SUDO fsck -n $1 2>/dev/null >&1)
		echo $CHECK_FS_MSG | grep "clean" >/dev/null 2>&1
		if [ $? = 0 ]; then
			CHECK_FS="ok"
		else
			CHECK_FS="ng"
		fi
		;;
	* ) 
		CHECK_FS_MSG="not supported file system"
		CHECK_FS="not_supported"
	esac
}

#######################################
# sns publish
# $1: message
#######################################

function sns_publish() {
	MESSAGE_ID=$(aws sns publish --topic-arn $SNS_TOPIC_ARN --message "$1")
}

#######################################
# config cloudwatch agent
#######################################
CLOUDWATCH_CFG=$(cat << EOF
{ 
    "agent": { 
        "metrics_collection_interval": 60, 
        "run_as_user": "root" 
    }, 
    "metrics": { 
        "append_dimensions": { 
            "AutoScalingGroupName": "${aws:AutoScalingGroupName}", 
            "ImageId": "${aws:ImageId}", 
            "InstanceId": "${aws:InstanceId}", 
            "InstanceType": "${aws:InstanceType}" 
        }, 
        "metrics_collected": { 
            "collectd": { 
                "metrics_aggregation_interval": 60 
            }, 
            "mem": { 
                "measurement": [ 
                    "mem_used_percent"
                ], 
                "metrics_collection_interval": 60 
            }, 
            "statsd": { 
                "metrics_aggregation_interval": 60, 
                "metrics_collection_interval": 60, 
                "service_address": ":8125" 
            }, 
            "swap": { 
                "measurement": [ 
                    "swap_used_percent"
                ], 
                "metrics_collection_interval": 60 
            } 
        } 
    } 
} 
EOF
)

#######################################
# install cloudwatchlog agent
#######################################
function install_cloudwatchlog_agent() {
	#$SUDO yum update -y
	$SUDO yum install -y awslogs
}

#######################################
# config cloudwatchlog agent
#######################################
CLOUDWATCHLOG_CFG=$(cat << EOF
[/var/log/cloud-init.log]
datetime_format = %Y-%m-%d %H:%M:%S.%f
file = /var/log/cloud-init.log
buffer_duration = 5000
log_stream_name = {instance_id}
initial_position = start_of_file
log_group_name = /var/log/cloud-init.log
[/var/log/check_ebs_snapshot_fs.log]
datetime_format = %Y-%m-%d %H:%M:%S.%f
file = /var/log/check_ebs_snapshot_fs.log
buffer_duration = 5000
log_stream_name = {instance_id}
initial_position = start_of_file
log_group_name = check_ebs_snapshot_fs.log
EOF
)

function config_cloudwatchlog_agent() {
	$SUDO sed -i -e "s/us-east-1/ap-northeast-1/" /etc/awslogs/awscli.conf
	echo "$CLOUDWATCHLOG_CFG" | $SUDO tee -a /etc/awslogs/awslogs.conf
}

#######################################
# start cloudwatchlog agent
#######################################
function start_cloudwatchlog_agent() {
	$SUDO service awslogsd start
}

#######################################
# check ebs snapshot fs
# $1: snapshot id
#######################################
function check_ebs_snapshot_fs() {
	if [ "$1" == "" ]; then
		time_echo "snapshot($SP_TAG_KEY:$SP_TAG_VALUE_NEED) was not found"
		exit 1
	else
		time_echo "snapshot($SP_TAG_KEY:$SP_TAG_VALUE_NEED) was found as $1"
	fi

	time_echo "creating volume from snapshot($1)"
	if [ $SKIP_CREATE_VOLUME == 0 ]; then
		create_EBS_volume $1
	else
		VOL_ID=$DEFAULT_VOL_ID
	fi
	time_echo "volume($VOL_ID) created"

	if [ $SKIP_ATTACH_VOLUME == 0 ]; then
		time_echo "volume($VOL_ID) attaching.."
		attach_EBS_volume $INSTANCE_ID $VOL_ID
		time_echo "volume($VOL_ID) attached"
	fi

	check_file_system $CHECK_DEVICE
	time_echo "file system($FS) ==> $CHECK_FS"
	time_echo "$CHECK_FS_MSG"

	if [ $SKIP_SNS_PUBLISH == 0 ]; then
		time_echo "message sending"
		sns_publish "Snapshot ID: $1, File System: $FS, MSG: $CHECK_FS_MSG"
		#echo $MESSAGE_ID
	fi

	if [ $SKIP_DETACH_VOLUME == 0 ]; then
		time_echo "volume($VOL_ID) detaching..."
		detach_EBS_volume $VOL_ID
		time_echo "volume($VOL_ID) detached"
	fi

	if [ $SKIP_DELETE_VOLUME == 0 ]; then
		time_echo "volume($VOL_ID) deleting..."
		delete_EBS_volume $VOL_ID
		time_echo "volume($VOL_ID) deleted"
	fi

	aws ec2 create-tags --region $REGION --resources $1 --tags Key=$SP_TAG_KEY,Value=$CHECK_FS
	time_echo "snapshot($1) taggged as $SP_TAG_KEY:$CHECK_FS"
}

#######################################
# main
#######################################

#######################################
# check input parameter
#######################################
#if [ "$1" == "" ]; then
#	time_echo "snapshot id is not provided"
#	exit 1
#elif [ "$1" == "TAG" ]; then
#	time_echo "trying to find snapshot $SP_TAG_KEY:$SP_TAG_VALUE_NEED"
#else
#	SNAPSHOT_ID=$1
#fi

time_echo "cloudwatchlog agent installing..."
install_cloudwatchlog_agent
config_cloudwatchlog_agent
start_cloudwatchlog_agent
time_echo "cloudwatchlog agent started"

time_echo "trying to get Instance id from meta data"
get_instance_id
time_echo "Instance id($INSTANCE_ID)"

SNAPSHOT_IDS=$(aws ec2 describe-snapshots --region $REGION --filters "Name=tag:$SP_TAG_KEY,Values=$SP_TAG_VALUE_NEED" --query "Snapshots[*].{ID:SnapshotId}" --output text)
#SNAPSHOT_ID=$(echo $SNAPSHOT_IDS | awk '{print $1}')

ary=(`echo $SNAPSHOT_IDS`)
time_echo "${#ary[@]} snapshot(s) were(was) found"
for i in `seq 1 ${#ary[@]}`
do
	time_echo "##### snapshot(${ary[$i-1]}) starting..."
	check_ebs_snapshot_fs ${ary[$i-1]}
	time_echo "##### snapshot(${ary[$i-1]}) done"
done

if [ $SHUTDOWN_AT_END == 1 ]; then
	$SUDO shutdown -h $SHUTDOWN_TIMEOUT
else
	exit 0
fi
