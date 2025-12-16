resource "aws_security_group_rule" "livekit_tcp_7880" {
  type              = "ingress"
  from_port         = 7880
  to_port           = 7880
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
}

resource "aws_security_group_rule" "livekit_tcp_7881" {
  type              = "ingress"
  from_port         = 7881
  to_port           = 7881
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
}

resource "aws_security_group_rule" "livekit_udp_50000_60000" {
  type              = "ingress"
  from_port         = 50000
  to_port           = 60000
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
}
