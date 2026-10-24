resource "aws_security_group" "db" {
  name        = "orders-db"
  description = "Database"
  vpc_id      = "vpc-00000000000000000"

  ingress {
    description = "Postgres"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "db" {
  identifier             = "orders"
  engine                 = "postgres"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  username               = "orders_admin"
  password               = var.db_password
  publicly_accessible    = true
  storage_encrypted      = false
  vpc_security_group_ids = [aws_security_group.db.id]
  skip_final_snapshot    = true
}

variable "db_password" {
  type = string
}
