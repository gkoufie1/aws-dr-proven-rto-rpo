# One logical database, two writable regional endpoints, plus a witness.
#
# Unlike the Aurora Global Database in the active-passive stack there is no
# primary: both clusters accept writes, and a commit returns only after it is
# durable in both regions' logs (synchronous, quorum with the witness). That is
# what makes RPO = 0 a design property here rather than a hope.

resource "aws_dsql_cluster" "east" {
  provider = aws.east

  deletion_protection_enabled = false # ephemeral lab: apply -> drill -> destroy

  multi_region_properties {
    witness_region = var.witness_region
  }

  tags = { Name = "${local.name}-east" }
}

resource "aws_dsql_cluster" "west" {
  provider = aws.west

  deletion_protection_enabled = false

  multi_region_properties {
    witness_region = var.witness_region
  }

  tags = { Name = "${local.name}-west" }
}

# Peering is declared from both sides; the clusters become ACTIVE only once
# each knows about the other.
resource "aws_dsql_cluster_peering" "east" {
  provider = aws.east

  identifier     = aws_dsql_cluster.east.identifier
  clusters       = [aws_dsql_cluster.west.arn]
  witness_region = var.witness_region
}

resource "aws_dsql_cluster_peering" "west" {
  provider = aws.west

  identifier     = aws_dsql_cluster.west.identifier
  clusters       = [aws_dsql_cluster.east.arn]
  witness_region = var.witness_region
}
