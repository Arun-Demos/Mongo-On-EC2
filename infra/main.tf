# --- AMI ---
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

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

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

  dynamic "ingress" {
    for_each = var.public_access ? [1] : []
    content {
      from_port   = 27017
      to_port     = 27017
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "Public access"
    }
  }

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
}

# --- Admin password ---
resource "random_password" "mongo_admin" {
  length  = 20
  special = true
}

resource "aws_ssm_parameter" "mongo_admin" {
  name        = "/mongo/admin_password"
  type        = "SecureString"
  value       = random_password.mongo_admin.result
}

# --- IAM role/profile ---
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
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.instance_name}-profile"
  role = aws_iam_role.ec2_role.name
}

# --- S3 backups ---
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
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
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
    id     = "expire-old"
    status = "Enabled"
    expiration { days = var.backup_retention_days }
    filter {}
  }
}

# --- Data volume ---
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
}

# --- Instance ---
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

      # Repo setup (Amazon Linux/Ubuntu detection)
      if [ -f /etc/system-release ]; then
        # Amazon Linux
        cat >/etc/yum.repos.d/mongodb-org.repo <<EOR
      [mongodb-org]
      name=MongoDB Repository
      baseurl=https://repo.mongodb.org/yum/amazon/2/mongodb-org/${MONGO_MAJOR}/x86_64/
      gpgcheck=1
      enabled=1
      gpgkey=https://www.mongodb.org/static/pgp/server-${MONGO_MAJOR}.asc
EOR
        yum install -y mongodb-org
      elif [ -f /etc/lsb-release ]; then
        apt-get update
        apt-get install -y wget gnupg
        wget -qO - https://www.mongodb.org/static/pgp/server-${MONGO_MAJOR}.asc | apt-key add -
        echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu \$(lsb_release -sc)/mongodb-org/${MONGO_MAJOR} multiverse" | tee /etc/apt/sources.list.d/mongodb-org.list
        apt-get update
        apt-get install -y mongodb-org
      fi

      # Prepare volume
      mkfs -t xfs /dev/xvdf || true
      mkdir -p /var/lib/mongo
      echo "/dev/xvdf /var/lib/mongo xfs defaults,noatime 0 2" >> /etc/fstab
      mount -a
      chown -R mongod:mongod /var/lib/mongo
      sed -i 's|dbPath:.*|dbPath: /var/lib/mongo|' /etc/mongod.conf

      # Bind localhost, private IP, and all interfaces
      PRIV_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
      sed -i "s/^  bindIp: .*/  bindIp: 127.0.0.1,${PRIV_IP},0.0.0.0/" /etc/mongod.conf

      # Enable auth
      if ! grep -q '^security:' /etc/mongod.conf; then
        echo "security:" >> /etc/mongod.conf
        echo "  authorization: enabled" >> /etc/mongod.conf
      else
        sed -i 's/^security:.*/security:\\n  authorization: enabled/' /etc/mongod.conf
      fi

      systemctl enable mongod
      systemctl start mongod
      sleep 5

      ADMIN_PASS=$(aws ssm get-parameter --with-decryption --name "/mongo/admin_password" --region ${AWS_REGION} --output text --query Parameter.Value)

      # Create admin user
      mongosh --quiet --eval '
        try {
          use("admin");
          db.createUser({user: "admin", pwd: "'"$ADMIN_PASS"'", roles:[{role:"root",db:"admin"}]});
        } catch(e) {}
      '

      systemctl restart mongod
      sleep 3

      # Init stardb + services collection
      cat >/root/init_stardb.js <<'EOS'
      const adminUser = "admin";
      const adminPwd  = process.env.ADMIN_PASS;
      const conn = new Mongo();
      const admin = conn.getDB("admin");
      admin.auth(adminUser, adminPwd);
      const db = conn.getDB("stardb");

      if (!db.getCollectionNames().includes("services")) {
        db.createCollection("services", {
          validator: {
            $jsonSchema: {
              bsonType: "object",
              required: ["name","subscribers","revenue"],
              properties: {
                name: {bsonType:"string",maxLength:50},
                subscribers:{bsonType:"int",minimum:0},
                revenue:{bsonType:"decimal"}
              }
            }
          },
          validationAction:"error"
        });
      }
      if (db.services.estimatedDocumentCount() === 0) {
        db.services.insertMany([
          {name:"StarVision",subscribers:NumberInt(12000),revenue:NumberDecimal("48000.00")},
          {name:"StarDocs",subscribers:NumberInt(8500),revenue:NumberDecimal("25500.00")},
          {name:"StarCloud",subscribers:NumberInt(15000),revenue:NumberDecimal("112000.00")},
          {name:"StarAI Engine",subscribers:NumberInt(6300),revenue:NumberDecimal("75500.00")}
        ]);
      }
      EOS
      ADMIN_PASS="$ADMIN_PASS" mongosh --quiet --eval "load('/root/init_stardb.js')"

      # Backup script
      cat >/opt/mongo-backup.sh <<'EOB'
      #!/bin/bash
      set -e
      now=$(date -u +'%Y-%m-%dT%H-%M-%SZ')
      host=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
      key="${PREFIX}/stardb-${host}-${now}.archive.gz"
      ADMIN_PASS=$(aws ssm get-parameter --with-decryption --name "/mongo/admin_password" --region "${AWS_REGION}" --output text --query Parameter.Value)
      mongodump --username admin --password "${ADMIN_PASS}" --authenticationDatabase admin --db stardb --archive | gzip | aws s3 cp - "s3://${BUCKET}/${key}" --region "${AWS_REGION}"
      EOB
      chmod +x /opt/mongo-backup.sh
      echo '${var.backup_cron} root AWS_REGION=${AWS_REGION} BUCKET=${BUCKET} PREFIX=${PREFIX} /opt/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1' > /etc/cron.d/mongo-backup
      systemctl restart crond
  CLOUDINIT
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.mongo.id
}
