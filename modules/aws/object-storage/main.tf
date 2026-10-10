# Logical "object-storage" on S3: private, encrypted, optional versioning and lifecycle.

variable "name" { type = string } # bucket name prefix; the account id is appended for uniqueness
variable "versioning" {
  type    = bool
  default = false
}
variable "tier" {
  type    = string
  default = "standard"
}
variable "retention_days" {
  type    = number
  default = null
}
variable "force_destroy" {
  type    = bool
  default = false
}
variable "access_keys" {
  type        = bool
  default     = false
  description = "Create an IAM user limited to this bucket and keep its key in Secrets Manager (for consumers on other providers)."
}
variable "production" {
  type    = bool
  default = false
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  bucket        = substr("${var.name}-${data.aws_caller_identity.current.account_id}", 0, 63)
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration { status = var.versioning ? "Enabled" : "Suspended" }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = var.retention_days != null || var.tier != "standard" ? 1 : 0
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "orkstage-default"
    status = "Enabled"
    filter {}
    dynamic "transition" {
      for_each = var.tier == "standard" ? [] : [1]
      content {
        days          = 30
        storage_class = var.tier == "archive" ? "GLACIER" : "STANDARD_IA"
      }
    }
    dynamic "expiration" {
      for_each = var.retention_days == null ? [] : [1]
      content { days = var.retention_days }
    }
  }
}

# Consumers outside AWS (a Vercel or Render app) cannot assume a role: they get a key that can
# only read and write this bucket. The key lives in state and in Secrets Manager, never in outputs.
resource "aws_iam_user" "access" {
  count = var.access_keys ? 1 : 0
  name  = substr("${var.name}-access", 0, 64)
}

resource "aws_iam_user_policy" "access" {
  count = var.access_keys ? 1 : 0
  name  = "bucket-access"
  user  = aws_iam_user.access[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.this.arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"], Resource = "${aws_s3_bucket.this.arn}/*" },
    ]
  })
}

resource "aws_iam_access_key" "access" {
  count = var.access_keys ? 1 : 0
  user  = aws_iam_user.access[0].name
}

data "aws_region" "current" {}

resource "aws_secretsmanager_secret" "access" {
  count                   = var.access_keys ? 1 : 0
  name                    = "${var.name}/access-key"
  recovery_window_in_days = var.production ? 30 : 0
}

resource "aws_secretsmanager_secret_version" "access" {
  count     = var.access_keys ? 1 : 0
  secret_id = aws_secretsmanager_secret.access[0].id
  secret_string = jsonencode({
    accessKeyId     = aws_iam_access_key.access[0].id
    secretAccessKey = aws_iam_access_key.access[0].secret
    bucket          = aws_s3_bucket.this.id
    region          = data.aws_region.current.region
  })
}

output "kind" { value = "object-storage" }
output "region" { value = data.aws_region.current.region }
# A reference, not a value: other providers read the key through the platform (readSecret).
output "secret_ref" { value = var.access_keys ? aws_secretsmanager_secret.access[0].arn : "" }
output "bucket" { value = aws_s3_bucket.this.id }
output "arn" { value = aws_s3_bucket.this.arn }
output "endpoint" { value = "https://${aws_s3_bucket.this.bucket_regional_domain_name}" }
