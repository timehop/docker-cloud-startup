#!/bin/bash

# Parameters
# -- Tutum Credentials: store your username and API Key in an S3 bucket that the
# EC2 Instance's IAM Role has permission to access
# Username: <CREDENTIALS_S3_BUCKET>/<ENVIRONMENT>/tutum_auth_user
# API Key: <CREDENTIALS_S3_BUCKET>/<ENVIRONMENT>/tutum_auth_api_key
CREDENTIALS_S3_BUCKET="xxx"
ENVIRONMENT="xxx" #e.g. "staging", "production"
# -- Deployment Timeout: The amount of time to wait for this node to be deployed
# before the attempt is abandoned
DEPLOYMENT_TIMEOUT="5m"

METADATA_SERVICE_URL="http://169.254.169.254/latest/meta-data"

# Find OS kind: yum (Fedora based) or apt (Debian based)?

OS_KIND="unknown"
if   which apt-get; then OS_KIND="debian"
elif which yum;     then OS_KIND="fedora"
fi

#Install dependencies

case "$OS_KIND" in
  debian)
    locale-gen en_GB.UTF-8
    apt-get update
    apt-get install -y python-pip jq
    ;;
  fedora)
    echo "en_GB.UTF-8" > /etc/locale.conf
    yum install -y python #Fedora doesn't have Python pre-installed
    #pip & jq aren't in the yum repos
    curl -O https://bootstrap.pypa.io/get-pip.py
    python get-pip.py
    curl -Lo /usr/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64
    chmod ugo+x /usr/bin/jq
    #We also need to configure sudo for the Tutum install to work
    echo "Defaults:root !requiretty" >> /etc/sudoers.d/91-cloud-sudoers-requiretty
    chmod 440 /etc/sudoers.d/91-cloud-sudoers-requiretty
    ;;
  unknown)
    echo "This OS is not supported"
    exit 2
    ;;
esac

pip install tutum==0.21.1 awscli==1.9.20

# Set AWS env vars

export AWS_DEFAULT_REGION=$(curl -fs ${METADATA_SERVICE_URL}/placement/availability-zone | sed 's/.$//')

# Set Tutum env vars

export TUTUM_USER=$(aws s3 cp s3://${CREDENTIALS_S3_BUCKET}/${ENVIRONMENT}/tutum_auth_user - --region ${AWS_DEFAULT_REGION})
export TUTUM_APIKEY=$(aws s3 cp s3://${CREDENTIALS_S3_BUCKET}/${ENVIRONMENT}/tutum_auth_api_key - --region ${AWS_DEFAULT_REGION})

# Register this node with Tutum

tutum node byo | sed -n 4p | source /dev/stdin

# Remove any old Tutum nodes

tutum node rm $(tutum node list | grep "Unreachable" | awk '{print $1}')

# Set Tutum UUID env var now that tutum-agent has been installed

export TUTUM_UUID=$(cat /etc/tutum/agent/tutum-agent.conf | jq -r .TutumUUID)

# Wait for node to be deployed

echo "Waiting for node to be deployed..."
timeout $DEPLOYMENT_TIMEOUT bash -c "while [ \"\$(tutum node inspect $TUTUM_UUID | jq -r .state)\" != \"Deployed\" ]; do sleep 10; done;" #TUTUM_UUID is purposefully not escaped
if [ $? != 0 ]; then echo "Node never came up"; exit 2; fi

# Set Tutum tags based on EC2 tags

INSTANCE_ID=$(curl -fs ${METADATA_SERVICE_URL}/instance-id)
EC2_TAGS=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" | jq -r '.Tags | map(select(.Key | contains("tutum"))) | .[].Value')

for TAG in $EC2_TAGS
do
  tutum tag add -t $TAG $TUTUM_UUID
done

# Cleanup instance

unset AWS_DEFAULT_REGION TUTUM_USER TUTUM_APIKEY TUTUM_UUID
pip uninstall tutum awscli -y
case "$OS_KIND" in
  debian)
    apt-get purge -y python-pip jq
    ;;
  fedora)
    pip uninstall pip -y
    rm /usr/bin/jq
    ;;
esac

# Cleanup history

cat /dev/null > ~/.bash_history && history -c
