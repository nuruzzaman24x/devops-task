# Kubernetes monitoring (kube-prometheus-stack)

Prerequisites: Helm, cert-manager, ingress-nginx, MetalLB, a default StorageClass.

```bash
kubectl apply -f k8s-monitoring/clusterissuer.yaml        # skip if selfsigned-issuer already exists
kubectl create namespace devops-task-monitoring
kubectl -n devops-task-monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 18 | tr -d '/+=')"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kps prometheus-community/kube-prometheus-stack --version 93.4.1 \
  -n devops-task-monitoring -f k8s-monitoring/values.yaml --wait --timeout 8m
kubectl apply -f k8s-monitoring/ingress-lb-service.yaml   # dedicated MetalLB address
kubectl apply -f k8s-monitoring/grafana-ingress.yaml      # https://grafana.devops-task.local.com
```

Read the Grafana password with:
`kubectl -n devops-task-monitoring get secret grafana-admin -o jsonpath="{.data.admin-password}" | base64 -d`

The Grafana password is never committed. Add the MetalLB address of the new Service to your hosts file for the domain.
