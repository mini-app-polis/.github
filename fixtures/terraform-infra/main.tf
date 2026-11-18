# A fixture for the terraform-infra profile. It declares no provider and no
# resource, so a plan or apply of it can change nothing anywhere.
terraform {
  required_version = ">= 1.6"
}

output "version" {
  value = "0.0.0"
}
