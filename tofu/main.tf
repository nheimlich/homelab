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
  allow_update_branch         = false
  allow_squash_merge          = true
  delete_branch_on_merge      = true
  has_issues                  = false
  has_projects                = false
  has_wiki                    = false
  homepage_url                = "https://k8s.nhlabs.org"
  web_commit_signoff_required = true
  squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"
}

resource "github_repository_ruleset" "main_protection" {
  name        = "homelab-protection"
  repository  = "homelab"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/main"]
      exclude = []
    }
  }

  bypass_actors {
    actor_id    = 5
    actor_type  = "RepositoryRole"
    bypass_mode = "always"
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true
    required_signatures     = true
  }
}
