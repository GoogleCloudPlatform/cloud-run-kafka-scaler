/*
 * Copyright 2025 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

terraform {
  required_version = ">= 1.3"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9" # Or latest compatible version
    }
  }
}

locals {
  tasks_sa_id   = coalesce(var.tasks_service_account_name, "${var.scaler_service_name}-tasks")
  scaler_sa_id  = format("%s%s-sa", var.scaler_sa_name_prefix, var.scaler_service_name)
  scheduler_job_name = "${var.scaler_service_name}-cron"
  scheduler_sa_id    = format("%s%s-sa", var.scheduler_sa_name_prefix, local.scheduler_job_name)

  tasks_sa_email   = "${local.tasks_sa_id}@${var.project_id}.iam.gserviceaccount.com"
  scaler_sa_email  = "${local.scaler_sa_id}@${var.project_id}.iam.gserviceaccount.com"
  scheduler_sa_email = "${local.scheduler_sa_id}@${var.project_id}.iam.gserviceaccount.com"

  # Environment variables for the scaler Cloud Run service
  scaler_env_vars = {
    KAFKA_TOPIC_ID                     = var.topic_id
    CONSUMER_GROUP_ID                  = var.consumer_group_id
    CYCLE_SECONDS                      = tostring(var.scaler_cycle_seconds)
    INVOKER_SERVICE_ACCOUNT_EMAIL      = local.tasks_sa_email
  }
}

data "google_project" "project" {
  project_id = var.project_id
}

# --- Cloud Tasks Resources ---

resource "google_cloud_tasks_queue" "queue" {
  project  = var.project_id
  location = var.region
  name     = var.cloud_tasks_queue_name
}

resource "google_service_account" "tasks_sa" {
  project      = var.project_id
  account_id   = local.tasks_sa_id
  create_ignore_already_exists = true
  display_name = "Service Account for Cloud Tasks Invoker"
}

# --- Kafka Autoscaler Service Account and Permissions ---

resource "google_service_account" "scaler_sa" {
  project      = var.project_id
  account_id   = local.scaler_sa_id
  create_ignore_already_exists = true
  display_name = "Service Account for Kafka Autoscaler"
}

# Grant Scaler SA permission to impersonate Consumer SA
resource "google_service_account_iam_member" "scaler_impersonate_consumer" {
  service_account_id = var.consumer_sa_email # This needs the projects/... format
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.scaler_sa_email}"
}

# Grant Scaler SA permission to read Artifact Registry
resource "google_project_iam_member" "scaler_artifactregistry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${local.scaler_sa_email}"
}

# Grant Scaler SA permission to access scaler config secret
resource "google_secret_manager_secret_iam_member" "scaler_access_scaler_config" {
  project   = var.project_id
  secret_id = var.scaler_config_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.scaler_sa_email}"
}

# Grant Scaler SA permission to access admin client secret
resource "google_secret_manager_secret_iam_member" "scaler_access_admin_client" {
  project   = var.project_id
  secret_id = var.admin_client_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.scaler_sa_email}"
}

# Grant Scaler SA permission to manage Cloud Run services
resource "google_project_iam_member" "scaler_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${local.scaler_sa_email}"
}

# Grant Scaler SA permission to enqueue tasks
resource "google_cloud_tasks_queue_iam_member" "scaler_tasks_enqueuer" {
  project  = google_cloud_tasks_queue.queue.project
  location = google_cloud_tasks_queue.queue.location
  name     = google_cloud_tasks_queue.queue.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${local.scaler_sa_email}"
}

# Grant Scaler SA permission to write metrics
resource "google_project_iam_member" "scaler_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${local.scaler_sa_email}"
}

# Grant Scaler SA permission to view monitoring data
resource "google_project_iam_member" "scaler_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${local.scaler_sa_email}"
}

# Optional: Grant Scaler SA permission to use Managed Kafka
resource "google_project_iam_member" "scaler_managed_kafka_client" {
  count    = var.grant_managed_kafka_client_role ? 1 : 0
  project  = var.project_id
  role     = "roles/managedkafka.client"
  member   = "serviceAccount:${local.scaler_sa_email}"
}

resource "time_sleep" "wait_for_scaler_sa_propagation" {
  # Wait for 15 seconds for the newly created service accounts to fully propagate
  # Feel free to adjust this value if needed.
  # This is needed to avoid errors like "Service account xxx does not exist" during `terraform apply`
  # See https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep
  create_duration = "15s"

  # Re-run the sleep if any of the IAM resources are created OR changed.
  # This ensures the delay is always applied, even if any of the IAM resources below are updated later.
  triggers = merge(
    # Map of triggers that are always present
    {
      scaler_impersonate_consumer = google_service_account_iam_member.scaler_impersonate_consumer.id
      scaler_artifactregistry = google_project_iam_member.scaler_artifactregistry_reader.id
      scaler_access_scaler_config = google_secret_manager_secret_iam_member.scaler_access_scaler_config.id
      scaler_access_admin_client  = google_secret_manager_secret_iam_member.scaler_access_admin_client.id
      scaler_run_admin            = google_project_iam_member.scaler_run_admin.id
      scaler_tasks_enqueuer       = google_cloud_tasks_queue_iam_member.scaler_tasks_enqueuer.id
      scaler_monitoring_writer    = google_project_iam_member.scaler_monitoring_writer.id
      scaler_monitoring_viewer    = google_project_iam_member.scaler_monitoring_viewer.id
    },
    # Conditionally add the kafka client role trigger ONLY if the resource exists (count > 0)
    # Creates map { scaler_managed_kafka_client = "<resource_id>" } when true, or {} when false.
    var.grant_managed_kafka_client_role ?
      { scaler_managed_kafka_client = google_project_iam_member.scaler_managed_kafka_client[0].id } 
    : {}
  )
}

# --- Deploy Kafka Autoscaler Cloud Run Service ---

resource "google_cloud_run_v2_service" "scaler_service" {
  project  = var.project_id
  location = var.region
  name     = var.scaler_service_name
  labels   = merge(
    {
      "created-by" = "scaler-kafka"
    },
    var.additional_labels
  )
  deletion_protection = false

  # Ensure that IAM bindings involving the SA exist, before creating the service that uses it
  depends_on = [
    google_service_account_iam_member.scaler_impersonate_consumer,
    google_project_iam_member.scaler_artifactregistry_reader,
    google_secret_manager_secret_iam_member.scaler_access_scaler_config,
    google_secret_manager_secret_iam_member.scaler_access_admin_client,
    google_project_iam_member.scaler_run_admin,
    google_cloud_tasks_queue_iam_member.scaler_tasks_enqueuer,
    google_project_iam_member.scaler_monitoring_writer,
    google_project_iam_member.scaler_monitoring_viewer,
    time_sleep.wait_for_scaler_sa_propagation,
    google_project_iam_member.scaler_managed_kafka_client,
  ]

  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = local.scaler_sa_email

    scaling {
      max_instance_count = 1
    }

    # VPC Access configuration - only include if network and subnet are provided
    vpc_access {
      # Set egress conditionally based on whether network/subnet are provided
      # Note: Default is ALL_TRAFFIC if network/subnet are null
      egress = (var.network != null && var.subnet != null) ? "PRIVATE_RANGES_ONLY" : "ALL_TRAFFIC"

      # Dynamically create the network_interfaces block only if network and subnet are provided
      dynamic "network_interfaces" {
        # The for_each iterates once if the condition is true, zero times if false
        for_each = (var.network != null && var.subnet != null) ? [1] : []

        content {
          network = var.network
          subnetwork  = var.subnet
        }
      }
    }


    volumes {
      name = "kafka-config"
      secret {
        secret = var.admin_client_secret_name
        items {
          path    = "kafka-client-properties"
          version = var.admin_client_secret_version
        }
      }
    }
    volumes {
      name = "scaler-config"
      secret {
        secret = var.scaler_config_secret_name
        items {
          path    = "scaling"
          version = var.scaler_config_secret_version 
        }
      }
    }

    containers {
      image = var.scaler_image_path
      base_image_uri = "us-central1-docker.pkg.dev/serverless-runtimes/google-22/runtimes/java17"

      env {
        name  = "KAFKA_TOPIC_ID"
        value = local.scaler_env_vars.KAFKA_TOPIC_ID
      }
      env {
        name  = "CONSUMER_GROUP_ID"
        value = local.scaler_env_vars.CONSUMER_GROUP_ID
      }
      env {
        name  = "CYCLE_SECONDS"
        value = local.scaler_env_vars.CYCLE_SECONDS
      }
      env {
        name  = "FULLY_QUALIFIED_CLOUD_TASKS_QUEUE_NAME"
        value = "projects/${var.project_id}/locations/${var.region}/queues/${google_cloud_tasks_queue.queue.name}"
      }
      env {
        name  = "INVOKER_SERVICE_ACCOUNT_EMAIL"
        value = local.scaler_env_vars.INVOKER_SERVICE_ACCOUNT_EMAIL
      }

      volume_mounts {
        name       = "kafka-config"
        mount_path = "/kafka-config"
      }
      volume_mounts {
        name       = "scaler-config"
        mount_path = "/scaler-config" 
      }
      # Define ports if needed, e.g.
      # ports {
      #   container_port = 8080
      # }
    }
  }
}

# Grant Tasks SA permission to invoke the Scaler Cloud Run service
resource "google_cloud_run_v2_service_iam_member" "tasks_invoke_scaler" {
  project  = google_cloud_run_v2_service.scaler_service.project
  location = google_cloud_run_v2_service.scaler_service.location
  name     = google_cloud_run_v2_service.scaler_service.name
  role     = "roles/run.invoker"
  member  = "serviceAccount:${local.tasks_sa_email}"
  depends_on = [
    google_service_account.tasks_sa,
    google_cloud_run_v2_service.scaler_service,
    time_sleep.wait_for_scaler_sa_propagation, # Ensure the SA exists before granting permission
  ]
}


# --- Cloud Scheduler Resources ---

resource "google_service_account" "scheduler_sa" {
  project      = var.project_id
  account_id   = local.scheduler_sa_id
  create_ignore_already_exists = true
  display_name = "Service Account for Cloud Scheduler Job"
}

# Grant Scheduler SA permission to invoke the Scaler Cloud Run service
resource "google_cloud_run_v2_service_iam_member" "scheduler_invoke_scaler" {
  project  = google_cloud_run_v2_service.scaler_service.project
  location = google_cloud_run_v2_service.scaler_service.location
  name     = google_cloud_run_v2_service.scaler_service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${local.scheduler_sa_email}"
  depends_on = [
    google_service_account.scheduler_sa,
    google_cloud_run_v2_service.scaler_service
  ]
}

resource "google_cloud_scheduler_job" "scaler_trigger" {
  project   = var.project_id
  region    = var.region
  name      = local.scheduler_job_name
  schedule  = var.scheduler_schedule
  time_zone = "Etc/UTC"

  http_target {
    uri = google_cloud_run_v2_service.scaler_service.uri # Use the URI from the created service

    oidc_token {
      service_account_email = local.scheduler_sa_email
      audience              = google_cloud_run_v2_service.scaler_service.uri 
    }
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.scheduler_invoke_scaler
  ]
}
