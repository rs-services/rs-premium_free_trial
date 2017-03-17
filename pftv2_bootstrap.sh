#!/usr/bin/env bash

# TODO: create schedules, test and publish cats
# A help option that'll print a useful usage message
if [[ "$*" == *"help"* ]]
then
  echo "Usage: pftv2_bootstrap.sh [options]"
  echo "  options:"
  echo "    all - Does bootstrapping of all following items. This is the default if no option is set"
  echo "    cats - Upserts all libraries and application cats"
  echo "    sts - Upserts all ServerTemplates"
  echo "    management - Launches management CATs for creating networks, MCI, and STs"
  echo "    creds - Upserts the PFT_RS_REFRESH_TOKEN credential with the value provided in OAUTH_REFRESH_TOKEN"
  echo "    schedule - Creates a 'Business Hours' CAT schedule"
fi

# By default, the script will perform "all" actions.
options="all"
if [[ -n "$*" ]]
then
  options=$*
fi

# Check for required environment variables
if [[ -z "$OAUTH_REFRESH_TOKEN" || -z "$ACCOUNT_ID" || -z "$SHARD_HOSTNAME" ]]
then
  echo "The following environment variables must be set. OAUTH_REFRESH_TOKEN, ACCOUNT_ID, SHARD_HOSTNAME"
  exit 1
fi
export RIGHT_ST_LOGIN_ACCOUNT_ID=$ACCOUNT_ID
export RIGHT_ST_LOGIN_ACCOUNT_HOST=$SHARD_HOSTNAME
export RIGHT_ST_LOGIN_ACCOUNT_REFRESH_TOKEN=$OAUTH_REFRESH_TOKEN

# Set a default (US) regional mapping, and check to see if the user specified an
# alternative mapping.
cat_list_file="pftv2_cat_list.txt"
echo "Checking for CAT_LIST_MODIFIER, used to replace the token CAT_LIST_MODIFIER in the pftv2_cat_list.txt file. Useful for alternate configs such as region specific mappings."
if [[ -z "$CAT_LIST_MODIFIER" ]]
then
  echo "The environment variable CAT_LIST_MODIFIER was not set, so it will be set to 'default'."
  export CAT_LIST_MODIFIER='default'
else
  echo "The environment variable CAT_LIST_MODIFIER was set to $CAT_LIST_MODIFIER..."
fi

# The RSC tool is required, check for it.
hasrsc=$(which rsc)
if [[ $? != 0 ]]
then
  echo "The binary 'rsc' must be installed - https://github.com/rightscale/rsc"
  exit 1
fi

# The JQ tool is required, check for it.
hasjq=$(which jq)
if [[ $? != 0 ]]
then
  echo "The binary 'jq' must be installed - https://stedolan.github.io/jq/"
  exit 1
fi

# The right_st tool is required, check for it.
hasrightst=$(which right_st)
if [[ $? != 0 ]]
then
  echo "The binary 'right_st' must be installed - https://github.com/rightscale/right_st"
  exit 1
fi

# Finally, if STS import is specified, and the Chef Server isn't already imported
# notify the user. They'll need to import it manually, since it requires accepting
# an EULA and can not be imported programatically.
if [[ "$options" == *"all"* || "$options" == *"sts"* ]]
then
  echo "Checking for Chef Server Template. This is a prerequsite to importing the ServerTemplates."
  chef_server_response=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME cm15 index server_templates "filter[]=name==Chef Server for Linux (RightLink 10)" "filter[]=revision==10")
  if [[ -z "$chef_server_response" ]]
  then
    echo "We need you to complete one manual step first. Go import the Chef Server for Linux (RightLink 10) and accept the EULA. Here's a handy link - http://www.rightscale.com/library/server_templates/Chef-Server-for-Linux-RightLin/lineage/57238"
    exit 1
  else
    echo "Chef Server Template found!"
  fi
fi

# Requires parameters.
# 1) The name of the management CAT to launch
management_cat_launch_wait_terminate_delete() {
  echo "Searching for management CAT template by name ($1)..."
  network_template_href=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss index /api/designer/collections/$ACCOUNT_ID/templates "filter[]=name==$1" --x1=.href)
  echo "Found ($1) template at href $network_template_href. Launching CloudApp..."
  network_cloud_app_href=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss create /api/manager/projects/$ACCOUNT_ID/executions "name=$1 - Bootstrap" "template_href=$network_template_href" --xh=Location)
  echo "CloudApp for template ($1) launched with execution href - $network_cloud_app_href. Waiting for completion..."
  status="unknown"
  while [[ "$status" != "running" && "$status" != "failed" ]]
  do
    status=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss show $network_cloud_app_href --x1=.status)
    if [[ "$status" != "running" && "$status" != "failed" ]]
    then
      echo "CloudApp is $status. Waiting 20 seconds before checking again..."
      sleep 20
    else
      break
    fi
  done

  if [[ "$status" == "failed" ]]
  then
    echo "WARNING: The management CAT named ($1) failed. We'll continue with other stuff, but you should probably check it out. It won't be automatically terminated."
  else
    echo "Terminating ($1) CloudApp..."
    terminate=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss terminate $network_cloud_app_href)
    status="unknown"
    while [[ "$status" != "terminated" && "$status" != "failed" ]]
    do
      status=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss show $network_cloud_app_href --x1=.status)
      if [[ "$status" != "terminated" && "$status" != "failed" ]]
      then
        echo "CloudApp is $status. Waiting 20 seconds before checking again..."
        sleep 20
      else
        break
      fi
    done
    echo "Deleting ($1) CloudApp..."
    delete=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss delete $network_cloud_app_href)
  fi
}

# Import CATs step.
if [[ "$options" == *"all"* || "$options" == *"cats"* ]]
then
  echo "Upserting CAT and library files."
  for i in `cat $cat_list_file`
  do
    cat_filename=$(echo $i | sed -e "s/CAT_LIST_MODIFIER/$CAT_LIST_MODIFIER/g")
    cat_name=$(sed -n -e "s/^name[[:space:]]['\"]*\(.*\)['\"]/\1/p" $cat_filename)
    echo "Checking to see if ($cat_name - $cat_filename) has already been uploaded..."
    cat_href=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss index collections/$ACCOUNT_ID/templates "filter[]=name==$cat_name" | jq -r '.[0].href')
    if [[ -z "$cat_href" ]]
    then
      echo "($cat_name - $i) not already uploaded, creating it now..."
      rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss create collections/$ACCOUNT_ID/templates source=$i
    else
      echo "($cat_name - $i) already uploaded, updating it now..."
      rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss update $cat_href source=$i
    fi
  done
else
  echo "Skipping CAT and library upsert."
fi

# Launch Management CATs step
if [[ "$options" == *"all"* || "$options" == *"management"* ]]
then
  echo "Launching management CATs."

  azure_clouds=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME cm15 index clouds "filter[]=cloud_type==azure_v2")
  if [[ -z "$azure_clouds" ]]
  then
    echo "No AzureV2 clouds, the network management CAT will not be executed"
  else
    management_cat_launch_wait_terminate_delete "PFT Admin CAT - PFT Network Setup"
  fi
  management_cat_launch_wait_terminate_delete "PFT Admin CAT - PFT Base Linux MCI Setup/Maintenance"
  management_cat_launch_wait_terminate_delete "PFT Admin CAT - PFT Base Linux ServerTemplate Setup/Maintenance"
  management_cat_launch_wait_terminate_delete "PFT Admin CAT - PFT Base Windows MCI Setup/Maintenance"
  management_cat_launch_wait_terminate_delete "PFT Admin CAT - PFT Base Windows ServerTemplate Setup/Maintenance"
  management_cat_launch_wait_terminate_delete "PFT Admin CAT - PFT LAMP ServerTemplates Prerequisite Import"
else
  echo "Skipping management CATs."
fi

# Right_ST upload ServerTemplates step
if [[ "$options" == *"all"* || "$options" == *"sts"* ]]
then
  echo "Upserting ServerTemplates."
  right_st st upload server_templates/chef_server/*.yml
  right_st st upload server_templates/haproxy-chef12/*.yml
  right_st st upload server_templates/mysql-chef12/*.yml
  right_st st upload server_templates/php-chef12/*.yml
else
  echo "Skipping ServerTemplates."
fi

# Set PFT_RS_REFRESH_TOKEN step
if [[ "$options" == *"all"* || "$options" == *"creds"* ]]
then
  echo "Upserting Credentials."
  echo "WARNING: On second thought, this is probably a pretty dangerous idea, since refresh tokens must be account specific for now. Please make sure that a valid PFT_RS_REFRESH_TOKEN credential exists. We'll automate this eventually."
  # existing=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME cm15 index credentials "filter[]=name==PFT_RS_REFRESH_TOKEN")
  # if [[ -z "$existing" ]]
  # then
  #   echo "PFT_RS_REFRESH_TOKEN Credential does not exist, creating it..."
  #   rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME cm15 create credentials "credential[name]=PFT_RS_REFRESH_TOKEN" "credential[value]=$OAUTH_REFRESH_TOKEN"
  # else
  #   echo "PFT_RS_REFRESH_TOKEN Credential already existed, updating it..."
  #   existing_href=$(echo $existing | jq -r ".[0].links[].href")
  #   rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME cm15 update $existing_href "credential[value]=$OAUTH_REFRESH_TOKEN"
  # fi
else
  echo "Skipping Credentials."
fi

# Create Business Hours schedule
if [[ "$options" == *"all"* || "$options" == *"schedule"* ]]
then
  echo "Checking for Business Hours Schedule."

  schedules_json=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss index /designer/collections/$ACCOUNT_ID/schedules)
  if [[ -z "$schedules_json" || -z "$(echo $schedules_json | rsc --xm ':has(.name:val("Business Hours")) > .id' json)" ]]
  then
    echo "Creating Business Hours Schedule..."
    schedule_create=$(rsc -r $OAUTH_REFRESH_TOKEN -a $ACCOUNT_ID -h $SHARD_HOSTNAME ss create /designer/collections/$ACCOUNT_ID/schedules "name=Business Hours" "start_recurrence[hour]=8" "start_recurrence[minute]=0" "start_recurrence[rule]=FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR" "stop_recurrence[hour]=18" "stop_recurrence[minute]=0" "stop_recurrence[rule]=FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
    echo $schedule_create
  else
    echo "Business Hours schedule already exists, not creating it."
  fi

else
  echo "Skipping Business Hours Schedule."
fi
