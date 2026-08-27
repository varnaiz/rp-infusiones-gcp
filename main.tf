terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Google Cloud Project ID"
  default     = "project-0eacb265-30c4-4a5a-9e8"
}

variable "region" {
  type        = string
  description = "Google Cloud Region for Spain/European operations"
  default     = "europe-west1"
}

variable "db_tier" {
  type        = string
  description = "Machine tier for Cloud SQL PostgreSQL"
  default     = "db-f1-micro"
}

variable "db_password" {
  type        = string
  description = "Cloud SQL database password (leave empty to generate automatically)"
  default     = ""
  sensitive   = true
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "random_password" "db_password" {
  length  = 16
  special = false
}

locals {
  db_password = var.db_password != "" ? var.db_password : random_password.db_password.result
}

# ------------------------------------------------------------------------------
# Service Accounts (IAM)
# ------------------------------------------------------------------------------
resource "google_service_account" "cloud_run_sa" {
  account_id   = "erp-cloud-run-sa-${random_id.suffix.hex}"
  display_name = "ERP Cloud Run Service Account"
  project      = var.project_id
}

resource "google_service_account" "workflows_sa" {
  account_id   = "erp-workflows-sa-${random_id.suffix.hex}"
  display_name = "ERP Cloud Workflows Service Account"
  project      = var.project_id
}

# ------------------------------------------------------------------------------
# Cloud SQL (PostgreSQL 15)
# ------------------------------------------------------------------------------
resource "google_sql_database_instance" "erp_database" {
  name                = "erp-database-${random_id.suffix.hex}"
  database_version    = "POSTGRES_15"
  region              = var.region
  project             = var.project_id
  deletion_protection = false

  settings {
    tier      = var.db_tier
    disk_size = 10
    disk_type = "PD_SSD"

    ip_configuration {
      ipv4_enabled = true
    }
  }
}

resource "google_sql_database" "erp_db" {
  name     = "erp_db"
  instance = google_sql_database_instance.erp_database.name
  project  = var.project_id
}

resource "google_sql_user" "erp_user" {
  name     = "erp_admin"
  instance = google_sql_database_instance.erp_database.name
  password = local.db_password
  project  = var.project_id
}

# ------------------------------------------------------------------------------
# Secret Manager
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret" "erp_db_credentials" {
  secret_id = "erp-db-credentials-${random_id.suffix.hex}"
  project   = var.project_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "erp_db_credentials_version" {
  secret = google_secret_manager_secret.erp_db_credentials.id
  secret_data = jsonencode({
    host     = google_sql_database_instance.erp_database.connection_name
    database = google_sql_database.erp_db.name
    username = google_sql_user.erp_user.name
    password = local.db_password
  })
}

# ------------------------------------------------------------------------------
# IAM Bindings
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.erp_db_credentials.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_project_iam_member" "cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_project_iam_member" "workflows_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.workflows_sa.email}"
}

# ------------------------------------------------------------------------------
# Pub/Sub Topic
# ------------------------------------------------------------------------------
resource "google_pubsub_topic" "erp_events" {
  name    = "erp-events-${random_id.suffix.hex}"
  project = var.project_id
}

# ------------------------------------------------------------------------------
# Cloud Workflows (Sintaxis de expresiones corregida)
# ------------------------------------------------------------------------------
resource "google_workflows_workflow" "erp_order_orchestrator" {
  name                = "erp-order-orchestrator-${random_id.suffix.hex}"
  region              = var.region
  project             = var.project_id
  description         = "Orchestrator for ERP orders lifecycle across sales, finance, inventory, and dispatch"
  service_account     = google_service_account.workflows_sa.id
  deletion_protection = false

  source_contents = <<-EOT
  main:
    params: [args]
    steps:
      - init:
          assign:
            - orderId: '$${default(args.orderId, "ORD-1001")}'
            - status: "RECEIVED"
      - validateOrder:
          call: sys.log
          args:
            text: '$${"Validating order: " + orderId}'
            severity: "INFO"
      - reserveInventory:
          call: sys.log
          args:
            text: '$${"Reserving tea products for order: " + orderId}'
            severity: "INFO"
      - processInvoice:
          call: sys.log
          args:
            text: '$${"Generating invoice and finance entry for order: " + orderId}'
            severity: "INFO"
      - notifyDispatch:
          call: sys.log
          args:
            text: '$${"Dispatching order to customer: " + orderId}'
            severity: "INFO"
      - complete:
          return:
            orderId: '$${orderId}'
            status: "COMPLETED"
  EOT
}

# ------------------------------------------------------------------------------
# Cloud Run Services
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "frontend_orders_service" {
  name                = "frontend-orders-service"
  location            = var.region
  project             = var.project_id
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.cloud_run_sa.email

    scaling {
      max_instance_count = 5
      min_instance_count = 0
    }

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      env {
        name  = "PUBSUB_TOPIC"
        value = google_pubsub_topic.erp_events.id
      }
      env {
        name  = "ENVIRONMENT"
        value = "production"
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "frontend_public_access" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.frontend_orders_service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service" "erp_core_service" {
  name                = "erp-core-service"
  location            = var.region
  project             = var.project_id
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.cloud_run_sa.email

    scaling {
      max_instance_count = 5
      min_instance_count = 0
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.erp_database.connection_name]
      }
    }

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      env {
        name  = "PUBSUB_TOPIC"
        value = google_pubsub_topic.erp_events.id
      }
      env {
        name  = "DB_CONNECTION_NAME"
        value = google_sql_database_instance.erp_database.connection_name
      }
      env {
        name = "DB_SECRET_ID"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.erp_db_credentials.secret_id
            version = "latest"
          }
        }
      }
    }
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------
output "frontend_url" {
  description = "Public URL of the frontend ordering web application"
  value       = google_cloud_run_v2_service.frontend_orders_service.uri
}

output "erp_core_url" {
  description = "URL of the core ERP backend service"
  value       = google_cloud_run_v2_service.erp_core_service.uri
}

output "cloud_sql_instance_connection_name" {
  description = "Connection name for Cloud SQL PostgreSQL instance"
  value       = google_sql_database_instance.erp_database.connection_name
}

output "pubsub_topic_name" {
  description = "Pub/Sub topic for ERP asynchronous events"
  value       = google_pubsub_topic.erp_events.name
}

output "workflow_id" {
  description = "ID of the Cloud Workflows orchestrator"
  value       = google_workflows_workflow.erp_order_orchestrator.id
}
