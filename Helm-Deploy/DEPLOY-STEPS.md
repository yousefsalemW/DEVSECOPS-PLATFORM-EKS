# Manual deploy — run once, then convert to a pipeline stage

All of this runs **on the Jenkins EC2 over SSM**, not from your laptop: the
cluster endpoint is private, so kubectl/helm only work from inside the VPC.

```bash
aws ssm start-session --target i-08c811b2aef8e05d5 --region eu-west-3
sudo -u jenkins -H bash
aws eks update-kubeconfig --name vprofile-eks --region eu-west-3
```

## 1. Platform layer (once per cluster)

```bash
bash platform/bootstrap-addons.sh
```

Installs the gp3 StorageClass (default) and the AWS Load Balancer Controller
bound to the existing `vprofile-lb-controller` IRSA role.

## 2. Deploy the app

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.eu-west-3.amazonaws.com"

# The exact tag your pipeline pushed — check the build log or:
aws ecr describe-images --repository-name vprofile-app --region eu-west-3 \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text

helm upgrade --install vprofile helm/vprofile \
  --namespace vprofile --create-namespace \
  --set image.registry="${REGISTRY}" \
  --set image.tag="<TAG>" \
  --timeout 10m
```

**Deliberately no `--atomic` on this first run.** If it fails, atomic rolls back
and deletes the pods you need to inspect.

## 3. Watch it

```bash
kubectl -n vprofile get pods -w
```

Expected order: `db01-0` Running/Ready → `app01` leaves Init → `vproweb` Ready.

## 4. Get the URL

```bash
kubectl -n vprofile get ingress vprofile \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Blank for 2-3 minutes while the ALB provisions. Open it in a browser — you
should get the VProfile login page. Credentials: `admin_vp` / `admin_vp`.

## If something breaks

```bash
kubectl -n vprofile describe pod <pod>          # events at the bottom
kubectl -n vprofile logs <pod> --tail=50
kubectl -n vprofile logs <app01-pod> -c wait-for-backends
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
kubectl -n vprofile get pvc                     # Pending = StorageClass problem
```

## Cost note

The Ingress is the ALB (~$0.65/day). When you stop working:

```bash
helm -n vprofile uninstall vprofile     # removes the ALB with it
```

The PVC survives an uninstall, so the database keeps its data. To wipe it too:
`kubectl -n vprofile delete pvc data-db01-0`

## Terraform follow-up (2 minutes, do it separately)

`vpc-cni` needs NetworkPolicy support turned on before any NetworkPolicy you
write will actually be enforced. It is an AWS API call, so unlike the addons
above it belongs in terraform and works fine from your laptop:

```hcl
cluster_addons = {
  coredns    = {}
  kube-proxy = {}
  vpc-cni = {
    configuration_values = jsonencode({ enableNetworkPolicy = "true" })
  }
}
```
