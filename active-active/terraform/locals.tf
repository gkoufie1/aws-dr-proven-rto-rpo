locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  api_fqdn = "${var.api_subdomain}.${var.hosted_zone_name}"

  dsql_endpoint = {
    (var.east_region) = "${aws_dsql_cluster.east.identifier}.dsql.${var.east_region}.on.aws"
    (var.west_region) = "${aws_dsql_cluster.west.identifier}.dsql.${var.west_region}.on.aws"
  }

  # Name of the FIS action the analyzer reads real start/end times from.
  fis_action_name = "fail-east-api"

  metric_namespace = "DrProof/ActiveActive"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "dr-evidence-active-active"
  }
}

data "aws_route53_zone" "this" {
  provider     = aws.east
  name         = var.hosted_zone_name
  private_zone = false
}
