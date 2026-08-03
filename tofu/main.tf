terraform {
  backend "local" {
    path = "./.ic_state/homelab/terraform.tfstate"
  }
}

module "github" {
  source = "./github/"
}

module "gcp" {
  source = "./gcp"
}

provider "github" {}

output "gcp_project_id" {
  value = module.gcp.project_id
}

output "gcp_oidc_issuer" {
  value = module.gcp.oidc_issuer
}

output "gcp_workload_identity_provider" {
  value = module.gcp.workload_identity_provider
}
