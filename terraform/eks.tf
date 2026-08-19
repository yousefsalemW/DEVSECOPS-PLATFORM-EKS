module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "vprofile-eks"
  cluster_version = "1.34"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  #JOIN API SERVER
  cluster_endpoint_public_access           = false
  cluster_endpoint_private_access          = true
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    workers = {
      instance_types = ["m7i-flex.large"]
      min_size       = 3
      max_size       = 5
      desired_size   = 3
    }
  }

  #Logs
  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]




  # Encryption Cluster data 
  create_kms_key = true

  cluster_encryption_config = {
    resources = ["secrets"]
  }


  # addons اللي مش محتاجة IRSA مخصص (الـ EBS CSI بره الـ module عشان نكسر الـ cycle)
  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    # NetworkPolicy enforcement is OFF by default in vpc-cni. Without this the API
    # server happily ACCEPTS every NetworkPolicy, kubectl displays them, and
    # nothing is ever enforced - which is worse than having none, because it looks
    # like segmentation exists.
    vpc-cni = {
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
  }
}

# IRSA: AWS Load Balancer Controller (الـ helm install بيستخدم الـ role ده)
module "lb_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "vprofile-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# IRSA: EBS CSI driver
module "ebs_csi_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "vprofile-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
resource "aws_security_group_rule" "jenkins_to_eks" {
  type      = "ingress"
  from_port = 443
  to_port   = 443
  protocol  = "tcp"

  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.jenkins.id

  description = "Allow Jenkins to access EKS API"
}


# الـ EBS CSI addon كـ resource مستقل — يكسر الـ dependency cycle مع module.eks
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.ebs_csi_role.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks] # يتأكد إن الـ nodes جاهزة الأول
}

# Jenkins EC2 role يقدر يعمل kubectl/helm على الـ cluster
resource "aws_eks_access_entry" "jenkins" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.jenkins.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.jenkins.arn
  # EditPolicy scoped to one namespace is everything `helm upgrade --install`
  # needs. ClusterAdmin gave every build - and anyone who can merge a commit -
  # read access to every Secret in every namespace, including kube-system.
  # Platform-level installs stay a human operation via bootstrap-addons.sh.
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["vprofile"]
  }
}
