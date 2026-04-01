locals {
  tags = merge(
    {
      Project     = var.cluster_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for EKS node registration

  tags = merge(local.tags, { Name = var.cluster_name })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.cluster_name}-igw" })
}

# ── Public Subnets ────────────────────────────────────────────────────────────
# One subnet per AZ. All subnets are public — no NAT Gateway to keep costs low.
# NOTE: nodes will have public IPs. Add private subnets + NAT GW for production.

resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-public-${var.availability_zones[count.index]}"
    # Required for EKS to discover subnets for node groups
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Required for EKS to provision internet-facing NLBs/ALBs into these subnets
    "kubernetes.io/role/elb" = "1"
  })
}

# ── Route Table ───────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${var.cluster_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
