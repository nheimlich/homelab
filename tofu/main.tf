terraform {
  backend "local" {
    path = "./.ic_state/terraform.tfstate"
  }
}

module "github" {
  source = "./github/"
}

module "gcp" {
  source = "./gcp"
}

provider "github" {}
provider "google" {}
