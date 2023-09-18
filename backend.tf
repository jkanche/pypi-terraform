terraform {
  backend "s3" {
    bucket = "pypi-terraform-state"
    region = "us-west-2"
    key    = "pypi.tfstate"
  }
}
