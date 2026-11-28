# Manual Infrastructure Setup (Fresh VM)

This documents how the host environment was prepared manually on a fresh VM,
useful for reproducing the setup outside of Terraform/CI.

## 1. AWS CLI

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo apt update
sudo apt install unzip -y
unzip awscliv2.zip
sudo ./aws/install
```

Configure credentials (in production, prefer an IAM instance role instead of
static keys — see the Security Considerations section of the main README):

```bash
aws configure
# AWS Access Key ID:     <YOUR_ACCESS_KEY>
# AWS Secret Access Key: <YOUR_SECRET_KEY>
# Default region name:   ap-south-1
```

## 2. Docker

```bash
sudo apt install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker
```

## 3. Kubernetes cluster

Cluster bootstrap steps are maintained in a separate repo:
[deploy-k8s-cluster](https://github.com/nuruzzaman24x/deploy-k8s-cluster.git)

```bash
git clone https://github.com/nuruzzaman24x/deploy-k8s-cluster.git
cd deploy-k8s-cluster
# follow setup steps in that repo's README
```

> For the EC2 target used by CI/CD (see README sections 7/8), this manual process
> is replaced by the Terraform `user_data.sh.tftpl` bootstrap script, which
> installs Docker automatically and uses an IAM instance profile instead of
> static AWS keys.
