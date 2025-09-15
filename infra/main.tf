# --- AMI ---
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"] # Amazon
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# --- Subnet info (for AZ & EBS) ---
data "aws_subnet" "selected" { id = var.subnet_id }

# --- SG ---
resource "aws_security_group" "mongo" {
  name        = "${var.instance_name}-sg"
  description = "MongoDB EC2 SG"
  vpc_id      = var.vpc_id

  # SSH (tighten or switch to SSM only)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  # Mongo from EKS SG (optional)
  dynamic "ingress" {
    for_each = var.eks_node_sg_id != "" ? [1] : []
    content {
      from_port       = 27017
      to_port         = 27017
      protocol        = "tcp"
      security_groups = [var.eks_node_sg_id]
      description     = "EKS -> Mongo"
    }
  }

  # Mongo from extra CIDRs (optional)
  dynamic "ingress" {
    for_each = var.allowed_cidrs
    content {
      from_port   = 27017
      to_port     = 27017
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.instance_name}-sg" }
}

# --- Random admin password (stored in SSM) ---
resource "random_password" "mongo_admin" {
  length  = 20
  special = true
}

resource "aws_ssm_parameter" "mongo_admin" {
  name        = "/mongo/admin_password"
  type        = "SecureString"
  value       = random_password.mongo_admin.result
  description = "MongoDB admin password"
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

# Allow SSM agent
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow reading admin password from SSM
data "aws_iam_policy_document" "ssm_read" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.mongo_admin.arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"] # or scope to your SSM KMS key if using a CMK
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

# Allow S3 backups
data "aws_iam_policy_document" "s3_backup" {
  statement {
    actions = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.mongo_backups.arn,
      "${aws_s3_bucket.mongo_backups.arn}/${var.backup_prefix}/*"
    ]
  }
}
resource "aws_iam_policy" "s3_backup" {
  name   = "${var.instance_name}-s3-backup"
  policy = data.aws_iam_policy_document.s3_backup.json
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
  tags = { Name = "${var.instance_name}-backups" }
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
    noncurrent_version_expiration { noncurrent_days = var.backup_retention_days }
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
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.mongo.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device { volume_size = var.root_volume_gb }

  user_data = <<-CLOUDINIT
  #cloud-config
  package_update: true
  packages: [jq, git, amazon-cloudwatch-agent, python3, unzip]

  runcmd:
    - |
      set -euxo pipefail
      MONGO_MAJOR="${var.mongo_version}"
      AWS_REGION="${var.aws_region}"
      BUCKET="${var.backup_bucket_name}"
      PREFIX="${var.backup_prefix}"

      # Add MongoDB repo
      cat >/etc/yum.repos.d/mongodb-org.repo <<'EOR'
      [mongodb-org]
      name=MongoDB Repository
      baseurl=https://repo.mongodb.org/yum/amazon/2/mongodb-org/${MONGO_MAJOR}/x86_64/
      gpgcheck=1
      enabled=1
      gpgkey=https://www.mongodb.org/static/pgp/server-${MONGO_MAJOR}.asc
      EOR

      yum install -y mongodb-org awscli

      # Prepare data volume
      mkfs -t xfs /dev/xvdf || true
      mkdir -p /var/lib/mongo
      echo "/dev/xvdf /var/lib/mongo xfs defaults,noatime 0 2" >> /etc/fstab
      mount -a

      chown -R mongod:mongod /var/lib/mongo
      sed -i 's|^  dbPath: .*|  dbPath: /var/lib/mongo|' /etc/mongod.conf

      # Bind to private IP only
      PRIV_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
      sed -i "s/^  bindIp: .*/  bindIp: 127.0.0.1,${PRIV_IP}/" /etc/mongod.conf

      # Enable auth
      if ! grep -q '^security:' /etc/mongod.conf; then
        printf "\nsecurity:\n  authorization: enabled\n" >> /etc/mongod.conf
      else
        sed -i 's/^security:.*/security:\n  authorization: enabled/' /etc/mongod.conf
      fi

      systemctl enable mongod
      systemctl start mongod
      sleep 5

      # Pull admin password from SSM
      ADMIN_PASS="$(aws ssm get-parameter --with-decryption --name "/mongo/admin_password" --region ${AWS_REGION} --output text --query Parameter.Value || true)"

      # Create admin user (idempotent)
      mongosh --quiet --eval '
        try {
          use("admin");
          db.createUser({user: "admin", pwd: "'"$ADMIN_PASS"'", roles: [ { role: "root", db: "admin" } ]});
        } catch (e) {}
      ' || true

      systemctl restart mongod
      sleep 3

      # Bootstrap stardb + services validator + seed data
      cat >/root/init_stardb.js <<'EOS'
      const adminUser = "admin";
      const adminPwd  = process.env.ADMIN_PASS;

      const conn = new Mongo();
      const admin = conn.getDB("admin");
      admin.auth(adminUser, adminPwd);

      const db = conn.getDB("stardb");
      db.runCommand({ ping: 1 });

      const coll = "services";
      const collections = db.getCollectionNames();

      if (!collections.includes(coll)) {
        db.createCollection(coll, {
          validator: {
            $jsonSchema: {
              bsonType: "object",
              required: ["name", "subscribers", "revenue"],
              properties: {
                name:        { bsonType: "string",  maxLength: 50 },
                subscribers: { bsonType: "int",     minimum: 0 },
                revenue:     { bsonType: "decimal" }
              }
            }
          },
          validationAction: "error"
        });
      } else {
        db.runCommand({
          collMod: coll,
          validator: {
            $jsonSchema: {
              bsonType: "object",
              required: ["name", "subscribers", "revenue"],
              properties: {
                name:        { bsonType: "string",  maxLength: 50 },
                subscribers: { bsonType: "int",     minimum: 0 },
                revenue:     { bsonType: "decimal" }
              }
            }
          },
          validationAction: "error"
        });
      }

      if (db.services.estimatedDocumentCount() === 0) {
        db.services.insertMany([
          { name: "StarVision",    subscribers: NumberInt(12000), revenue: NumberDecimal("48000.00") },
          { name: "StarDocs",      subscribers: NumberInt(8500),  revenue: NumberDecimal("25500.00") },
          { name: "StarCloud",     subscribers: NumberInt(15000), revenue: NumberDecimal("112000.00") },
          { name: "StarAI Engine", subscribers: NumberInt(6300),  revenue: NumberDecimal("75500.00") }
        ]);
      }
      EOS

      ADMIN_PASS="$ADMIN_PASS" mongosh --quiet --eval "load('/root/init_stardb.js')"

      # Backup script
      cat >/opt/mongo-backup.sh <<'EOB'
      #!/usr/bin/env bash
      set -euo pipefail
      AWS_REGION="${AWS_REGION}"
      BUCKET="${BUCKET}"
      PREFIX="${PREFIX}"

      now=$(date -u +'%Y-%m-%dT%H-%M-%SZ')
      host=$(curl -s http://169.254.169.254/latest/meta-data/instance-id || echo "unknown-host")
      key="${PREFIX}/stardb-${host}-${now}.archive.gz"

      ADMIN_PASS=$(aws ssm get-parameter --with-decryption --name "/mongo/admin_password" --region "${AWS_REGION}" --output text --query Parameter.Value)

      mongodump \
        --username admin \
        --password "${ADMIN_PASS}" \
        --authenticationDatabase admin \
        --db stardb \
        --archive | gzip -c | \
        aws s3 cp - "s3://${BUCKET}/${key}" --region "${AWS_REGION}"

      echo "Uploaded backup to s3://${BUCKET}/${key}"
      EOB
      chmod +x /opt/mongo-backup.sh
      echo "AWS_REGION=${AWS_REGION}" >> /etc/environment
      echo "BUCKET=${BUCKET}"         >> /etc/environment
      echo "PREFIX=${PREFIX}"         >> /etc/environment

      # Cron
      echo '${var.backup_cron} root . /etc/environment && /opt/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1' > /etc/cron.d/mongo-backup
      chmod 644 /etc/cron.d/mongo-backup
      systemctl restart crond

      # CloudWatch logs (optional)
      cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'EOCW'
      {
        "logs": {
          "logs_collected": {
            "files": {
              "collect_list": [
                { "file_path": "/var/log/mongodb/mongod.log", "log_group_name": "mongodb-ec2", "log_stream_name": "{instance_id}/mongod.log" },
                { "file_path": "/var/log/mongo-backup.log",   "log_group_name": "mongodb-ec2", "log_stream_name": "{instance_id}/backup.log" }
              ]
            }
          }
        }
      }
      EOCW
      systemctl enable amazon-cloudwatch-agent
      systemctl restart amazon-cloudwatch-agent
  CLOUDINIT

  tags = { Name = var.instance_name }
}

# Attach data volume
resource "aws_volume_attachment" "data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.mongo.id
}
