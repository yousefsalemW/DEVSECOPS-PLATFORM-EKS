terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "vprofilealnaqib777"   # اعمل الـ bucket مرة واحدة
    key          = "eks/terraform.tfstate"
    region       = "eu-west-3"
    use_lockfile = true                       # S3 native locking (بدل dynamodb_table)
  }
}
