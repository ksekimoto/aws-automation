#!/bin/bash

ROLE_NAME="check_ebs_fs"
POLICY_NAME=$ROLE_NAME
PROFILE_NAME="${ROLE_NAME}_profile"

assume_role_policy_document=$(jq -c . <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

role=$(aws iam create-role \
  --role-name  "$ROLE_NAME" \
  --assume-role-policy-document "$assume_role_policy_document" | jq -c . )

policy_document=$(jq -c . <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:*"],
      "Resource": ["*"]
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name $ROLE_NAME \
  --policy-name $POLICY_NAME \
  --policy-document "$policy_document"

aws iam create-instance-profile --instance-profile-name $PROFILE_NAME

aws iam add-role-to-instance-profile \
  --instance-profile-name $PROFILE_NAME \
  --role-name $ROLE_NAME
