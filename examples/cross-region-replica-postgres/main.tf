provider "aws" {
  region = local.region1
}

provider "aws" {
  alias  = "region2"
  region = local.region2
}

data "aws_caller_identity" "current" {}

locals {
  name    = "replica-postgresql"
  region1 = "ap-east-1"
  region2 = "ap-southeast-1"


  tags = {
    Name       = local.name
    Example    = local.name
    Repository = "https://github.com/terraform-aws-modules/terraform-aws-rds"
  }

  engine                = "postgres"
  engine_version        = "13"
  family                = "postgres13" # DB parameter group
  major_engine_version  = "13"         # DB option group
  instance_class        = "db.t4g.2xlarge"
  storage_type          = "io1"
  iops                  = 12000
  allocated_storage     = 400
  max_allocated_storage = 800
  port                  = 5432

  replica_instance_class = "db.t4g.xlarge"
}

################################################################################
# Master DB
################################################################################

module "master" {
  source = "../../"

  identifier = "${local.name}-master"

  engine               = local.engine
  engine_version       = local.engine_version
  family               = local.family
  major_engine_version = local.major_engine_version
  instance_class       = local.instance_class

  storage_type          = local.storage_type
  iops                  = local.iops
  allocated_storage     = local.allocated_storage
  max_allocated_storage = local.max_allocated_storage

  db_name  = "replicaPostgresql"
  username = "replica_postgresql"
  port     = local.port

  multi_az               = true
  db_subnet_group_name   = module.vpc_region1.database_subnet_group_name
  vpc_security_group_ids = [module.security_group_region1.security_group_id]

  maintenance_window              = "Mon:00:00-Mon:03:00"
  backup_window                   = "03:00-06:00"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Backups are required in order to create a replica
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  create_monitoring_role          = true
  monitoring_interval             = 60
  monitoring_role_name            = "example-monitoring-role-name"
  monitoring_role_use_name_prefix = true
  monitoring_role_description     = "Description for monitoring role"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  tags = local.tags
}


################################################################################
# RDS Automated Backups Replication Module
################################################################################

module "db_automated_backups_replication" {
  source = "../../modules/db_instance_automated_backups_replication"

  source_db_instance_arn = module.master.db_instance_arn
  kms_key_arn            = module.kms.key_arn

  providers = {
    aws = aws.region2
  }
}

################################################################################
# Replica DB
################################################################################

module "kms" {
  source      = "terraform-aws-modules/kms/aws"
  version     = "~> 1.0"
  description = "KMS key for cross region replica DB"

  # Aliases
  aliases                 = [local.name]
  aliases_use_name_prefix = true

  key_owners = [data.aws_caller_identity.current.id]

  tags = local.tags

  providers = {
    aws = aws.region2
  }
}

module "replica" {
  source = "../../"

  providers = {
    aws = aws.region2
  }

  identifier = "${local.name}-replica"

  # Source database. For cross-region use db_instance_arn
  replicate_source_db    = module.master.db_instance_arn
  create_random_password = false

  engine               = local.engine
  engine_version       = local.engine_version
  family               = local.family
  major_engine_version = local.major_engine_version
  instance_class       = local.replica_instance_class
  kms_key_id           = module.kms.key_arn

  allocated_storage     = local.allocated_storage
  max_allocated_storage = local.max_allocated_storage

  # Username and password should not be set for replicas
  username = null
  password = null
  port     = local.port

  multi_az               = false
  vpc_security_group_ids = [module.security_group_region2.security_group_id]

  maintenance_window              = "Tue:00:00-Tue:03:00"
  backup_window                   = "03:00-06:00"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false

  # Specify a subnet group created in the replica region
  db_subnet_group_name = module.vpc_region2.database_subnet_group_name

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

module "vpc_region1" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = "10.100.0.0/18"

  azs              = ["${local.region1}a", "${local.region1}b", "${local.region1}c"]
  public_subnets   = ["10.100.0.0/24", "10.100.1.0/24", "10.100.2.0/24"]
  private_subnets  = ["10.100.3.0/24", "10.100.4.0/24", "10.100.5.0/24"]
  database_subnets = ["10.100.7.0/24", "10.100.8.0/24", "10.100.9.0/24"]

  create_database_subnet_group = true

  tags = local.tags
}

module "security_group_region1" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = local.name
  description = "Replica PostgreSQL example security group"
  vpc_id      = module.vpc_region1.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "PostgreSQL access from within VPC"
      cidr_blocks = module.vpc_region1.vpc_cidr_block
    },
  ]

  tags = local.tags
}

module "vpc_region2" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  providers = {
    aws = aws.region2
  }

  name = local.name
  cidr = "10.100.0.0/18"

  azs              = ["${local.region2}a", "${local.region2}b", "${local.region2}c"]
  public_subnets   = ["10.100.0.0/24", "10.100.1.0/24", "10.100.2.0/24"]
  private_subnets  = ["10.100.3.0/24", "10.100.4.0/24", "10.100.5.0/24"]
  database_subnets = ["10.100.7.0/24", "10.100.8.0/24", "10.100.9.0/24"]

  create_database_subnet_group = true

  tags = local.tags
}

module "security_group_region2" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  providers = {
    aws = aws.region2
  }

  name        = local.name
  description = "Replica PostgreSQL example security group"
  vpc_id      = module.vpc_region2.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "PostgreSQL access from within VPC"
      cidr_blocks = module.vpc_region2.vpc_cidr_block
    },
  ]

  tags = local.tags
}
