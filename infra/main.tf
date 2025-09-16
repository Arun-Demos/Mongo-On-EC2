# --- AMI (supports older distros via name filter) ---
data "aws_ami" "linux" {
  most_recent = true
  owners      = [var.linux_ami_owner]
  filter {
    name   = "name"
    values = [var.linux_ami_filter]
  }
}

# --- Subnet info ---
data "aws_subnet" "selected" { id = var.subnet_id }

# --- Security Group ---
resource "aws_security_group" "mongo" {
  name        = "${var.instance_name}-sg"
  description = "MongoDB SG"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  # Allow EKS nodes (pods -> private IP)
  dynamic "ingress" {
    for_each = var.eks_node_sg_id != "" ? [1] : []
    content {
      from_port       = 27017
      to_port         = 27017
      protocol        = "tcp"
      security_groups = [var.eks_node_sg_id]
      description     = "EKS -> Mongo (private IP)"
    }
  }

  # Optional public access
  dynamic "ingress" {
    for_each = var.public_access ? [1] : []
    content {
      from_port   = 27017
      to_port     = 27017
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "Public access (27017)"
    }
  }

  # Optional extra CIDRs
  dynamic "ingress" {
    for_each = var.allowed_cidrs
    content {
      from_port   = 27017
      to_port     = 27017
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
      description = "Extra allowed CIDR"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Admin password in SSM ---
resource "random_password" "mongo_admin" {
  length  = 20
  special = true
}

resource "aws_ssm_parameter" "mongo_admin" {
  name  = "/mongo/admin_password"
  type  = "SecureString"
  value = random_password.mongo_admin.result
}

# --- IAM for EC2 ---
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["ec2.amazonaws.com"] }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${var.instance_name}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# SSM core (SSM agent, Session Manager)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read SSM parameter (and decrypt with AWS-managed KMS key for SSM)
data "aws_iam_policy_document" "ssm_read" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.mongo_admin.arn]
  }
  statement {
    actions = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:ssm:parameter-name"
      values   = [aws_ssm_parameter.mongo_admin.name]
    }
  }
}

resource "aws_iam_policy" "ssm_read" {
  name   = "${var.instance_name}-read-ssm"
  policy = data.aws_iam_policy_document.ssm_read.json
}

resource "aws_iam_role_policy_attachment" "ssm_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ssm_read.arn
}

# S3 backup write permissions
resource "aws_iam_policy" "s3_backup" {
  name   = "${var.instance_name}-s3-backup"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListBucket"],
        Resource = [
          aws_s3_bucket.mongo_backups.arn,
          "${aws_s3_bucket.mongo_backups.arn}/${var.backup_prefix}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_backup" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_backup.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.instance_name}-profile"
  role = aws_iam_role.ec2_role.name
}

# --- S3 backups bucket ---
resource "aws_s3_bucket" "mongo_backups" {
  bucket        = var.backup_bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "mongo_backups" {
  bucket = aws_s3_bucket.mongo_backups.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mongo_backups" {
  bucket = aws_s3_bucket.mongo_backups.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "mongo_backups" {
  bucket                  = aws_s3_bucket.mongo_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "mongo_backups" {
  bucket = aws_s3_bucket.mongo_backups.id
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    expiration { days = var.backup_retention_days }
    filter {}
  }
}

# --- EBS data volume ---
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  tags = { Name = "${var.instance_name}-data" }
}

# --- EC2 instance ---
resource "aws_instance" "mongo" {
  ami                    = data.aws_ami.linux.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.mongo.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device { volume_size = var.root_volume_gb }

  user_data = <<-CLOUDINIT
  #cloud-config
  package_update: true
  packages: [jq, git, awscli]

  runcmd:
    - |
      set -eux
      MONGO_MAJOR="${var.mongo_version}"
      AWS_REGION="${var.aws_region}"
      BUCKET="${var.backup_bucket_name}"
      PREFIX="${var.backup_prefix}"
      PUBLIC="${var.public_access}"

      # --- OS detection & Mongo repo install (supports Amazon Linux & Ubuntu) ---
      if [ -f /etc/system-release ]; then
        # Amazon Linux / AL2 / AL2023
        cat >/etc/yum.repos.d/mongodb-org.repo <<EOR
[mongodb-org]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2/mongodb-org/${MONGO_MAJOR}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-${MONGO_MAJOR}.asc
EOR
        yum install -y xfsprogs mongodb-org
      elif [ -f /etc/lsb-release ] || [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y wget gnupg xfsprogs
        wget -qO - https://www.mongodb.org/static/pgp/server-${MONGO_MAJOR}.asc | apt-key add -
        # Try to derive codename, default to focal if unknown (works for Ubuntu 20.04)
        CODENAME="$(lsb_release -sc 2>/dev/null || echo focal)"
        echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu ${CODENAME}/mongodb-org/${MONGO_MAJOR} multiverse" \
          | tee /etc/apt/sources.list.d/mongodb-org.list
        apt-get update
        apt-get install -y mongodb-org
      else
        echo "Unsupported distro; attempting yum..."
        yum install -y xfsprogs mongodb-org || true
      fi

      # --- Data volume ---
      mkfs -t xfs /dev/xvdf || true
      mkdir -p /var/lib/mongo
      echo "/dev/xvdf /var/lib/mongo xfs defaults,noatime 0 2" >> /etc/fstab
      mount -a
      chown -R mongod:mongod /var/lib/mongo

      # Ensure dbPath in mongod.conf
      sed -i 's|dbPath:.*|dbPath: /var/lib/mongo|' /etc/mongod.conf || true
      if ! grep -q 'dbPath:' /etc/mongod.conf; then
        mkdir -p /etc
        echo -e "storage:\n  dbPath: /var/lib/mongo" >> /etc/mongod.conf
      fi

      # Bind addresses: localhost + private IP (+ all if PUBLIC=true)
      PRIV_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 || echo 127.0.0.1)
      BIND_LIST="127.0.0.1,${PRIV_IP}"
      if [ "$PUBLIC" = "true" ]; then
        BIND_LIST="$BIND_LIST,0.0.0.0"
      fi
      if grep -q '^ *bindIp:' /etc/mongod.conf; then
        sed -i "s/^ *bindIp: .*/  bindIp: ${BIND_LIST}/" /etc/mongod.conf
      else
        sed -i "/^net:/a\  bindIp: ${BIND_LIST}" /etc/mongod.conf || echo -e "net:\n  bindIp: ${BIND_LIST}" >> /etc/mongod.conf
      fi

      # Enable auth
      if ! grep -q '^security:' /etc/mongod.conf; then
        echo -e "security:\n  authorization: enabled" >> /etc/mongod.conf
      else
        sed -i 's/^security:.*/security:\\n  authorization: enabled/' /etc/mongod.conf
      fi

      systemctl enable mongod
      systemctl start mongod
      sleep 5

      # --- Admin user ---
      ADMIN_PASS=$(aws ssm get-parameter --with-decryption --name "/mongo/admin_password" --region ${AWS_REGION} --output text --query Parameter.Value)
      mongosh --quiet --eval '
        try {
          use("admin");
          db.createUser({user: "admin", pwd: "'"$ADMIN_PASS"'", roles:[{role:"root",db:"admin"}]});
        } catch(e) {}
      '
      systemctl restart mongod
      sleep 3

      # --- Seed files from Terraform (schema + data) ---
      mkdir -p /root/seed
      cat >/root/seed/schema.js <<'EOSCHEMA'
${file("${path.module}/../seed/schema.js")}
EOSCHEMA

      cat >/root/seed/data.js <<'EODATA'
${file("${path.module}/../seed/data.js")}
EODATA

      # Apply schema (idempotent)
      mongosh --quiet -u admin -p "$ADMIN_PASS" --authenticationDatabase admin stardb /root/seed/schema.js || true

      # Seed only if empty
      COUNT=$(mongosh --quiet -u admin -p "$ADMIN_PASS" --authenticationDatabase admin --eval "db.services.countDocuments()" stardb || echo 0)
      if [ "$COUNT" -eq 0 ]; then
        mongosh --quiet -u admin -p "$ADMIN_PASS" --authenticationDatabase admin stardb /root/seed/data.js
      fi

      # --- Backup script & cron ---
      cat >/opt/mongo-backup.sh <<'EOB'
#!/bin/bash
set -e
AWS_REGION="${AWS_REGION}"
BUCKET="${BUCKET}"
PREFIX="${PREFIX}"
now=$(date -u +'%Y-%m-%dT%H-%M-%SZ')
host=$(curl -s http://169.254.169.254/latest/meta-data/instance-id || echo unknown)
key="${PREFIX}/stardb-${host}-${now}.archive.gz"
ADMIN_PASS=$(aws ssm get-parameter --with-decryption --name "/mongo/admin_password" --region "${AWS_REGION}" --output text --query Parameter.Value)
mongodump --username admin --password "${ADMIN_PASS}" --authenticationDatabase admin --db stardb --archive | gzip | aws s3 cp - "s3://${BUCKET}/${key}" --region "${AWS_REGION}"
echo "Uploaded backup to s3://${BUCKET}/${key}"
EOB
      chmod +x /opt/mongo-backup.sh
      echo '${var.backup_cron} root AWS_REGION=${AWS_REGION} BUCKET=${BUCKET} PREFIX=${PREFIX} /opt/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1' > /etc/cron.d/mongo-backup
      systemctl restart crond
  CLOUDINIT

  tags = { Name = var.instance_name }
}

# Attach data volume
resource "aws_volume_attachment" "data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.mongo.id
}
