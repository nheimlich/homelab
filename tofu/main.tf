terraform {
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "github" {}

resource "github_repository" "homelab" {
  name                        = "homelab"
  description                 = "Personal Kubernetes Cluster"
  visibility                  = "public"
  allow_merge_commit          = false
  allow_rebase_merge          = false
  allow_update_branch         = true
  allow_squash_merge          = true
  delete_branch_on_merge      = true
  has_issues                  = false
  has_projects                = false
  has_wiki                    = false
  homepage_url                = "https://k8s.nhlabs.org"
  web_commit_signoff_required = true
  allow_forking               = false
  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "PR_BODY"
}
