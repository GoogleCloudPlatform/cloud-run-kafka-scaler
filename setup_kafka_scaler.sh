#!/bin/bash
# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http:#www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



printf "Verify environment variables to be used:\n"
printf "\nDeployed Kafka consumer details:\n"
if [[ -v CONSUMER_SERVICE_NAME ]]; then
  echo "CONSUMER_SERVICE_NAME: " $CONSUMER_SERVICE_NAME
else
  echo "***** CONSUMER_SERVICE_NAME is not set. ***** "
fi
if [[ -v CONSUMER_SA_EMAIL ]]; then
  echo "CONSUMER_SA_EMAIL: " $CONSUMER_SA_EMAIL
else
  echo "***** CONSUMER_SA_EMAIL is not set. ***** "
fi
if [[ -v PROJECT_ID ]]; then
  echo "PROJECT_ID: " $PROJECT_ID
else
  echo "***** PROJECT_ID is not set. ***** "
fi
if [[ -v REGION ]]; then
  echo "REGION: " $REGION
else
  echo "***** REGION is not set. ***** "
fi
if [[ -v TOPIC_ID ]]; then
  echo "TOPIC_ID: " $TOPIC_ID
else
  echo "***** TOPIC_ID is not set. ***** "
fi
if [[ -v CONSUMER_GROUP_ID ]]; then
  echo "CONSUMER_GROUP_ID: " $CONSUMER_GROUP_ID
else
  echo "***** CONSUMER_GROUP_ID is not set. ***** "
fi

FULLY_QUALIFIED_CONSUMER_NAME=projects/$PROJECT_ID/locations/$REGION/workerpools/$CONSUMER_SERVICE_NAME

printf "\nKafka auth secret created in previous step:\n"
if [[ -v ADMIN_CLIENT_SECRET ]]; then
  echo "ADMIN_CLIENT_SECRET is set."
else
  echo "***** ADMIN_CLIENT_SECRET is not set. ***** "
fi
if [[ -v SCALER_CONFIG_SECRET ]]; then
  echo "SCALER_CONFIG_SECRET is set."
else
  echo "***** SCALER_CONFIG_SECRET is not set. ***** "
fi

printf "\nNew components that will be created: \n"
printf "Cloud Tasks:\n"
if [[ -v CLOUD_TASKS_QUEUE_NAME ]]; then
  echo "CLOUD_TASKS_QUEUE_NAME: " $CLOUD_TASKS_QUEUE_NAME
else
  echo "***** CLOUD_TASKS_QUEUE_NAME is not set. ***** "
fi
if [[ -v TASKS_SERVICE_ACCOUNT ]]; then
  echo "TASKS_SERVICE_ACCOUNT: " $TASKS_SERVICE_ACCOUNT
else
  echo "***** TASKS_SERVICE_ACCOUNT is not set. ***** "
fi

FULLY_QUALIFIED_CLOUD_TASKS_QUEUE_NAME=projects/$PROJECT_ID/locations/$REGION/queues/$CLOUD_TASKS_QUEUE_NAME

printf "\nKafka autoscaler:\n"
if [[ -v SCALER_SERVICE_NAME ]]; then
  echo "SCALER_SERVICE_NAME: " $SCALER_SERVICE_NAME
else
  echo "***** SCALER_SERVICE_NAME is not set. ***** "
fi
if [[ -v SCALER_IMAGE_PATH ]]; then
  echo "SCALER_IMAGE_PATH: " $SCALER_IMAGE_PATH
else
  echo "***** SCALER_IMAGE_PATH is not set. ***** "
fi
if [[ -v NETWORK ]]; then
  echo "NETWORK: " $NETWORK
else
  echo "***** NETWORK is not set. ***** "
fi
if [[ -v SUBNET ]]; then
  echo "SUBNET: " $SUBNET
else
  echo "***** SUBNET is not set. ***** "
fi

SCALER_SA_NAME=$SCALER_SERVICE_NAME-sa

printf "\nAutoscaling frequency:\n"
if [[ -v CYCLE_SECONDS ]]; then
  echo "CYCLE_SECONDS: " $CYCLE_SECONDS
else
  echo "***** CYCLE_SECONDS is not set. ***** "
fi

# Cloud Scheduler Job
CLOUD_SCHEDULER_JOB=$SCALER_SERVICE_NAME-cron
CLOUD_SCHEDULER_SA=$CLOUD_SCHEDULER_JOB-sa

read -p "Press any key to continue..."
###################################

####
# Cloud Tasks setup
####

# Create Cloud Tasks Queue
gcloud tasks queues create $CLOUD_TASKS_QUEUE_NAME --location=$REGION

# Create Tasks service account
gcloud iam service-accounts create $TASKS_SERVICE_ACCOUNT

####
# Kafka autoscaler setup
####

# Create Kafka autoscaler service account
gcloud iam service-accounts create $SCALER_SA_NAME

# Delay to allow time for propagation
sleep 5

# Grant necessary permissions to Kafka autoscaler service account
gcloud iam service-accounts add-iam-policy-binding $CONSUMER_SA_EMAIL \
    --member="serviceAccount:$SCALER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" \
    --condition=None --quiet

gcloud secrets add-iam-policy-binding $SCALER_CONFIG_SECRET \
    --member="serviceAccount:$SCALER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None --quiet

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SCALER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/run.admin" \
    --condition=None --quiet

gcloud tasks queues add-iam-policy-binding $CLOUD_TASKS_QUEUE_NAME \
    --member="serviceAccount:$SCALER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/cloudtasks.enqueuer" \
    --location=$REGION \
    --quiet

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SCALER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/monitoring.metricWriter" \
    --condition=None --quiet

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SCALER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/monitoring.viewer" \
    --condition=None --quiet

# Setup Kafka scaler env vars file
echo -n 'KAFKA_TOPIC_ID: $TOPIC_ID
CONSUMER_GROUP_ID: $CONSUMER_GROUP_ID
CYCLE_SECONDS: "$CYCLE_SECONDS"
FULLY_QUALIFIED_CLOUD_TASKS_QUEUE_NAME: $FULLY_QUALIFIED_CLOUD_TASKS_QUEUE_NAME
INVOKER_SERVICE_ACCOUNT_EMAIL: $TASKS_SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com' > scaler_env_vars.yaml

####
# Deploy the Kafka autoscaler
####
gcloud run deploy $SCALER_SERVICE_NAME \
    --region=$REGION \
    --image=$SCALER_IMAGE_PATH \
    --base-image=us-central1-docker.pkg.dev/serverless-runtimes/google-22/runtimes/java17 \
    --no-allow-unauthenticated \
    --vpc-egress=private-ranges-only \
    --network=$NETWORK \
    --subnet=$SUBNET \
    --service-account="$SCALER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --max-instances=1 \
    --update-secrets=/kafka-config/kafka-client-properties=$ADMIN_CLIENT_SECRET:latest \
    --update-secrets=/scaler-config/scaling=$SCALER_CONFIG_SECRET:latest \
    --labels=created-by=scaler-kafka
    --env-vars-file=scaler_env_vars.yaml

# Grant Tasks service account Cloud Run Invoker on the Kafka autoscaler
gcloud run services add-iam-policy-binding $SCALER_SERVICE_NAME \
    --member="serviceAccount:$TASKS_SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/run.invoker" \
    --quiet

####
# Create Cloud Scheduler Job to trigger Kafka autoscaler checks
####

#Create a service account for Cloud Scheduler:
gcloud iam service-accounts create $CLOUD_SCHEDULER_SA \
    --description="Service Acount for Cloud Scheduler to invoke Cloud Run" \
    --project=$PROJECT_ID

# Delay for propagation
sleep 5

#Add necessary permissions (may have to wait a few moments SA to exist):
gcloud run services add-iam-policy-binding $SCALER_SERVICE_NAME \
    --member="serviceAccount:$CLOUD_SCHEDULER_SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/run.invoker"

#Create scheduler job:
SCALER_URL=$(gcloud run services describe $SCALER_SERVICE_NAME --region us-central1 --format="value[](status.address.url)")

gcloud scheduler jobs create http $CLOUD_SCHEDULER_JOB \
   --location=$REGION \
   --schedule="* * * * *" \
   --uri=$SCALER_URL \
   --oidc-service-account-email=$CLOUD_SCHEDULER_SA@$PROJECT_ID.iam.gserviceaccount.com \
   --oidc-token-audience=$SCALER_URL

# Cleanup
rm -f scaler_env_vars.yaml