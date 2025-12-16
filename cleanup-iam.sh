#!/bin/bash
echo "=== Cleaning up IAM Resources ==="

# 1. EKS Cluster Role
echo "1. Cleaning EKS cluster role..."
aws iam list-attached-role-policies --role-name staging-demo-eks-cluster --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null | while read POLICY_ARN; do
  echo "  Detaching: $POLICY_ARN"
  aws iam detach-role-policy --role-name staging-demo-eks-cluster --policy-arn "$POLICY_ARN" 2>/dev/null
done
aws iam delete-role --role-name staging-demo-eks-cluster 2>/dev/null && echo "  ✓ Role deleted" || echo "  ✗ Role not found"

# 2. EKS Nodes Role
echo "2. Cleaning EKS nodes role..."
aws iam list-attached-role-policies --role-name staging-demo-eks-nodes --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null | while read POLICY_ARN; do
  echo "  Detaching: $POLICY_ARN"
  aws iam detach-role-policy --role-name staging-demo-eks-nodes --policy-arn "$POLICY_ARN" 2>/dev/null
done
aws iam delete-role --role-name staging-demo-eks-nodes 2>/dev/null && echo "  ✓ Role deleted" || echo "  ✗ Role not found"

# 3. Load Balancer Controller Policy
echo "3. Cleaning Load Balancer Controller policy..."
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='AWSLoadBalancerController'].Arn" --output text 2>/dev/null)
if [ -n "$POLICY_ARN" ]; then
  echo "  Policy ARN: $POLICY_ARN"
  
  # Detach from all roles
  aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query "PolicyRoles[].RoleName" --output text 2>/dev/null | while read ROLE_NAME; do
    echo "  Detaching from role: $ROLE_NAME"
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null
  done
  
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null && echo "  ✓ Policy deleted" || echo "  ✗ Policy deletion failed"
else
  echo "  Policy not found"
fi

echo "=== Cleanup Complete ==="
