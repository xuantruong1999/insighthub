provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "insighthub"
      ManagedBy = "terraform"
      Day       = "3"
    }
  }
}

# Cluster already exists (lab: do NOT create EKS). Configure the k8s provider
# against it via standard kubeconfig/exec; left to the environment for apply.
provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = var.cluster_ca_certificate != "" ? base64decode(var.cluster_ca_certificate) : null
}
