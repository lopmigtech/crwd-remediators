provider "aws" {
  region = "us-east-1"
}

module "s3_access_logging" {
  source = "../../"

  name_prefix            = "example"
  log_destination_bucket = "example-access-logs-bucket"
  log_destination_prefix = "s3-logs/"

  tags = {
    Environment = "dev"
  }
}
