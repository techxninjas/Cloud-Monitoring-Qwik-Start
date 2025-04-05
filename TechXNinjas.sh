#!/bin/bash

# ─────────────────────────────────────────────
#           COLOR AND TEXT FORMATTING
# ─────────────────────────────────────────────
BLACK_TEXT=$'\033[0;90m'
RED_TEXT=$'\033[0;91m'
GREEN_TEXT=$'\033[0;92m'
YELLOW_TEXT=$'\033[0;93m'
BLUE_TEXT=$'\033[0;94m'
MAGENTA_TEXT=$'\033[0;95m'
CYAN_TEXT=$'\033[0;96m'
WHITE_TEXT=$'\033[0;97m'
NO_COLOR=$'\033[0m'
RESET_FORMAT=$'\033[0m'

BOLD_TEXT=$'\033[1m'
UNDERLINE_TEXT=$'\033[4m'

clear

# ─────────────────────────────────────────────
#                WELCOME BANNER
# ─────────────────────────────────────────────
echo "${BLUE_TEXT}${BOLD_TEXT}"
echo "╔═════════════════════════════════════════════╗"
echo "║         INITIATING EXECUTION...            ║"
echo "╚═════════════════════════════════════════════╝"
echo "${RESET_FORMAT}"
echo

# ─────────────────────────────────────────────
#          PROMPT USER FOR GCP ZONE
# ─────────────────────────────────────────────
echo "${YELLOW_TEXT}${BOLD_TEXT}Please enter your GCP Zone:${RESET_FORMAT}"
read -r ZONE
export ZONE

echo "${CYAN_TEXT}${BOLD_TEXT}Creating a new VM instance... Please wait.${RESET_FORMAT}"

# ─────────────────────────────────────────────
#      CREATE GCP VM INSTANCE WITH METADATA
# ─────────────────────────────────────────────
gcloud compute instances create lamp-1-vm \
    --project=$DEVSHELL_PROJECT_ID \
    --zone=$ZONE \
    --machine-type=e2-small \
    --network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
    --metadata=enable-oslogin=true \
    --maintenance-policy=MIGRATE \
    --provisioning-model=STANDARD \
    --tags=http-server \
    --create-disk=auto-delete=yes,boot=yes,device-name=lamp-1-vm,image=projects/debian-cloud/global/images/debian-12-bookworm-v20240709,mode=rw,size=10,type=projects/$DEVSHELL_PROJECT_ID/zones/$ZONE/diskTypes/pd-balanced \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=goog-ec-src=vm_add-gcloud \
    --reservation-affinity=any

# ─────────────────────────────────────────────
#        CREATE FIREWALL RULE FOR HTTP
# ─────────────────────────────────────────────
echo "${YELLOW_TEXT}${BOLD_TEXT}Creating a firewall rule to allow HTTP traffic...${RESET_FORMAT}"

gcloud compute firewall-rules create allow-http \
    --project=$DEVSHELL_PROJECT_ID \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:80 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=http-server

sleep 10

# ─────────────────────────────────────────────
#               GENERATE SSH KEYS
# ─────────────────────────────────────────────
echo "${MAGENTA_TEXT}${BOLD_TEXT}Generating SSH keys...${RESET_FORMAT}"
gcloud compute config-ssh --project "$DEVSHELL_PROJECT_ID" --quiet

# ─────────────────────────────────────────────
#     INSTALL APACHE AND PHP ON THE VM
# ─────────────────────────────────────────────
echo "${CYAN_TEXT}${BOLD_TEXT}Installing Apache and PHP on the VM...${RESET_FORMAT}"
gcloud compute ssh lamp-1-vm --project "$DEVSHELL_PROJECT_ID" --zone $ZONE \
    --command "sudo sed -i '/buster-backports/d' /etc/apt/sources.list && sudo apt-get update && sudo apt-get install apache2 php7.3 -y && sudo service apache2 restart"

sleep 10

# ─────────────────────────────────────────────
#         FETCH INSTANCE ID FOR MONITORING
# ─────────────────────────────────────────────
echo "${GREEN_TEXT}${BOLD_TEXT}Fetching Instance ID...${RESET_FORMAT}"
INSTANCE_ID="$(gcloud compute instances describe lamp-1-vm --project=$DEVSHELL_PROJECT_ID --zone=$ZONE --format='value(id)')"

# ─────────────────────────────────────────────
#              SETUP UPTIME MONITORING
# ─────────────────────────────────────────────
echo "${BLUE_TEXT}${BOLD_TEXT}Setting up Uptime Monitoring...${RESET_FORMAT}"

gcloud monitoring uptime create lamp-uptime-check \
  --resource-type="gce-instance" \
  --resource-labels=project_id=$DEVSHELL_PROJECT_ID,instance_id=$INSTANCE_ID,zone=$ZONE

# ─────────────────────────────────────────────
#         CREATE EMAIL NOTIFICATION CHANNEL
# ─────────────────────────────────────────────
echo "${YELLOW_TEXT}${BOLD_TEXT}Creating an email notification channel...${RESET_FORMAT}"

cat > email-channel.json <<EOF_END
{
  "type": "email",
  "displayName": "techxninjas",
  "description": "techxninjas",
  "labels": {
    "email_address": "$USER_EMAIL"
  }
}
EOF_END

gcloud beta monitoring channels create --channel-content-from-file="email-channel.json"

# ─────────────────────────────────────────────
#               FETCH CHANNEL ID
# ─────────────────────────────────────────────
echo "${CYAN_TEXT}${BOLD_TEXT}Fetching channel ID...${RESET_FORMAT}"
channel_info=$(gcloud beta monitoring channels list)
channel_id=$(echo "$channel_info" | grep -oP 'name: \K[^ ]+' | head -n 1)

# ─────────────────────────────────────────────
#           CREATE ALERT POLICY JSON
# ─────────────────────────────────────────────
echo "${MAGENTA_TEXT}${BOLD_TEXT}Creating an alert policy for network traffic...${RESET_FORMAT}"

cat > app-engine-error-percent-policy.json <<EOF_END
{
  "displayName": "Inbound Traffic Alert",
  "userLabels": {},
  "conditions": [
    {
      "displayName": "VM Instance - Network traffic",
      "conditionThreshold": {
        "filter": "resource.type = \"gce_instance\" AND metric.type = \"agent.googleapis.com/interface/traffic\"",
        "aggregations": [
          {
            "alignmentPeriod": "300s",
            "crossSeriesReducer": "REDUCE_NONE",
            "perSeriesAligner": "ALIGN_RATE"
          }
        ],
        "comparison": "COMPARISON_GT",
        "duration": "60s",
        "trigger": {
          "count": 1
        },
        "thresholdValue": 500
      }
    }
  ],
  "alertStrategy": {},
  "combiner": "OR",
  "enabled": true,
  "notificationChannels": [
    "$channel_id"
  ],
  "severity": "SEVERITY_UNSPECIFIED"
}
EOF_END

gcloud alpha monitoring policies create --policy-from-file="app-engine-error-percent-policy.json"

# ─────────────────────────────────────────────
#       FINAL UPTIME CHECK (REDUNDANT ONE)
# ─────────────────────────────────────────────
INSTANCE_ID=$(gcloud compute instances describe lamp-1-vm --zone=$ZONE --format='value(id)')

gcloud monitoring uptime create lamp-uptime-check \
  --resource-type="gce-instance" \
  --resource-labels=project_id=$DEVSHELL_PROJECT_ID,instance_id=$INSTANCE_ID,zone=$ZONE

# ─────────────────────────────────────────────
#              COMPLETION MESSAGE
# ─────────────────────────────────────────────
echo
echo "${GREEN_TEXT}${BOLD_TEXT}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║              LAB COMPLETED SUCCESSFULLY!              ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo "${RESET_FORMAT}"
echo
echo -e "${RED_TEXT}${BOLD_TEXT}Subscribe to TechXNinjas:${RESET_FORMAT} ${BLUE_TEXT}${BOLD_TEXT}https://www.youtube.com/@Arcade61432${RESET_FORMAT}"
