output "project_id" {
  value = google_project.homelab.project_id
}

output "project_number" {
  value = google_project.homelab.number
}

output "oidc_issuer" {
  value = "https://nhlabs.org/oidc"
}

output "workload_identity_provider" {
  value = "//iam.googleapis.com/projects/${google_project.homelab.number}/locations/global/workloadIdentityPools/homelab/providers/k8s-oidc"
}
