terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.23.0"
    }
  }
}

data "google_billing_account" "acct" {
  display_name = "My Billing Account"
  open         = true
}

resource "random_id" "id" {
  byte_length = 8
}

resource "google_project" "homelab" {
  name            = "homelab"
  project_id      = "homelab-${random_id.id.hex}"
  deletion_policy = "DELETE"

  auto_create_network = false
  billing_account     = data.google_billing_account.acct.id
}

provider "google" {
  alias                 = "project_scoped"
  project               = google_project.homelab.project_id
  region                = "us-central1"
  user_project_override = true

  billing_project = google_project.homelab.project_id
}
