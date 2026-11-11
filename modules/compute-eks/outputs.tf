output "cluster_name" {
  value = aws_eks_cluster.this.name
}

# EKS attaches this security group to the control plane and to every managed node.
# Pods use their node's network identity, so this is the group the database must allow.
output "app_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
