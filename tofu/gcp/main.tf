terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.23.0"
    }
  }
}

data "google_billing_account" "acct" {
  provider = google.bootstrap

  display_name = "My Billing Account"
  open         = true
}

resource "random_id" "id" {
  byte_length = 8
}

provider "google" {
  alias = "bootstrap"
}

resource "google_project" "homelab" {
  provider = google.bootstrap

  name            = "homelab"
  project_id      = "homelab-${random_id.id.hex}"
  deletion_policy = "PREVENT"

  auto_create_network = false
  billing_account     = data.google_billing_account.acct.id
}

provider "google" {
  project               = google_project.homelab.project_id
  region                = "us-central1"
  user_project_override = true

  billing_project = google_project.homelab.project_id
}

resource "google_project_service" "iam" {
  project            = google_project.homelab.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  project            = google_project.homelab.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_iam_workload_identity_pool" "homelab" {
  project                   = google_project.homelab.project_id
  workload_identity_pool_id = "homelab"
  display_name              = "homelab"
  description               = "Kubernetes service account identities from the homelab Talos cluster"
}

resource "google_iam_workload_identity_pool_provider" "k8s_oidc" {
  project                            = google_project.homelab.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.homelab.workload_identity_pool_id
  workload_identity_pool_provider_id = "k8s-oidc"
  display_name                       = "k8s-oidc"
  description                        = "OIDC provider for the homelab cluster"

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  oidc {
    issuer_uri        = "https://nhlabs.org/oidc"
    allowed_audiences = ["//iam.googleapis.com/projects/${google_project.homelab.number}/locations/global/workloadIdentityPools/homelab/providers/k8s-oidc"]
  }
}

locals {
  eso_principal = "principal://iam.googleapis.com/projects/${google_project.homelab.number}/locations/global/workloadIdentityPools/homelab/subject/system:serviceaccount:external-secrets:external-secrets"
}

resource "google_secret_manager_secret" "cloudflare_token" {
  project   = google_project.homelab.project_id
  secret_id = "cloudflare-token"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "cloudflare_token" {
  secret      = google_secret_manager_secret.cloudflare_token.id
  secret_data = file("${path.module}/../../secrets/cloudflare-token.json")
}

resource "google_secret_manager_secret_iam_binding" "cloudflare_token_eso" {
  project   = google_project.homelab.project_id
  secret_id = google_secret_manager_secret.cloudflare_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  members   = [local.eso_principal]
}

resource "google_secret_manager_secret" "argocd_github" {
  project   = google_project.homelab.project_id
  secret_id = "argocd-github"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "argocd_github" {
  secret      = google_secret_manager_secret.argocd_github.id
  secret_data = file("${path.module}/../../secrets/argocd-github.json")
}

resource "google_secret_manager_secret_iam_binding" "argocd_github_eso" {
  project   = google_project.homelab.project_id
  secret_id = google_secret_manager_secret.argocd_github.secret_id
  role      = "roles/secretmanager.secretAccessor"
  members   = [local.eso_principal]
}

resource "google_secret_manager_secret" "talos_secrets" {
  project   = google_project.homelab.project_id
  secret_id = "talos-secrets"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "talos_secrets" {
  secret      = google_secret_manager_secret.talos_secrets.id
  secret_data = file("${path.module}/../../secrets/talos-secrets.yaml")
}

resource "google_secret_manager_secret" "talos_macaddr_sol" {
  project   = google_project.homelab.project_id
  secret_id = "talos-macaddr-sol"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "talos_macaddr_sol" {
  secret      = google_secret_manager_secret.talos_macaddr_sol.id
  secret_data = file("${path.module}/../../secrets/talos-macaddr-sol")
}

resource "google_secret_manager_secret" "talos_macaddr_clu" {
  project   = google_project.homelab.project_id
  secret_id = "talos-macaddr-clu"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "talos_macaddr_clu" {
  secret      = google_secret_manager_secret.talos_macaddr_clu.id
  secret_data = file("${path.module}/../../secrets/talos-macaddr-clu")
}

resource "google_secret_manager_secret" "talos_macaddr_ion" {
  project   = google_project.homelab.project_id
  secret_id = "talos-macaddr-ion"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "talos_macaddr_ion" {
  secret      = google_secret_manager_secret.talos_macaddr_ion.id
  secret_data = file("${path.module}/../../secrets/talos-macaddr-ion")
}

resource "google_monitoring_notification_channel" "budget_email" {
  project      = google_project.homelab.project_id
  display_name = "homelab budget alerts"
  type         = "email"

  labels = {
    email_address = "nolan@nhlabs.org"
  }
}

resource "google_billing_budget" "homelab" {
  billing_account = data.google_billing_account.acct.id
  display_name    = "homelab"

  amount {
    specified_amount {
      currency_code = "USD"
      units         = 1
    }
  }

  budget_filter {
    projects = [google_project.homelab.id]
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.9
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.budget_email.id]
  }
}
