# K8s Operator with OLM

A Kubernetes operator built with Operator SDK and deployed via Operator Lifecycle Manager (OLM).

## Overview

This operator manages two deployments (`web-application` and `data-db`) through a Custom Resource Definition (CRD) called `K8soperator`.

## Prerequisites

- Kubernetes cluster with OLM installed
- Docker registry access
- Tools: `operator-sdk`, `opm`, `kubectl`, `docker`

## Architecture

```
Custom Resource (CR) → CRD → Operator Controller → Managed Resources
```

## CRD Development Process

### 1. Initialize Operator Project
```bash
operator-sdk init --domain=mydomain.com --repo=github.com/user/k8soperator
```

### 2. Create API and Controller
```bash
operator-sdk create api --group=apps --version=v1alpha1 --kind=K8soperator --resource --controller
```

### 3. Define CRD Schema
Edit `api/v1alpha1/k8soperator_types.go`:
```go
type K8soperatorSpec struct {
    Replicas int32 `json:"replicas,omitempty"`
}
```

### 4. Generate CRD Manifests
```bash
make generate manifests
```

## OLM Deployment Process

### 1. Build and Push Operator Image
```bash
make build docker-build docker-push IMG=<registry>/k8soperator:v0.1.2
```

### 2. Generate OLM Bundle
```bash
make bundle VERSION=0.1.2
make bundle-build bundle-push BUNDLE_IMG=<registry>/k8soperator-bundle:v0.1.2
```

### 3. Create Catalog Index
```bash
make catalog-render catalog-build catalog-push INDEX_IMG=<registry>/k8soperator-index:v0.1.2
```

### 4. Deploy via OLM
```bash
# Create CatalogSource
kubectl apply -f catalogsource.yaml

# Create OperatorGroup
kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: k8soperator-operatorgroup
  namespace: default
spec:
  targetNamespaces:
  - default
EOF

# Create Subscription
kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: k8soperator-subscription
  namespace: default
spec:
  channel: stable
  name: k8soperator
  source: k8soperator-catalog
  sourceNamespace: olm
EOF
```

## How CRD Gets Installed

1. **Bundle Creation**: CRD manifests are packaged in the operator bundle
2. **CSV Definition**: ClusterServiceVersion references the CRD in `spec.customresourcedefinitions.owned`
3. **OLM Installation**: When subscription is created, OLM:
   - Reads the CSV from catalog
   - Installs CRDs defined in CSV
   - Deploys operator controller
   - Manages lifecycle

## Usage

Create a Custom Resource:
```yaml
apiVersion: apps.mydomain.com/v1alpha1
kind: K8soperator
metadata:
  name: k8soperator-sample
  namespace: default
spec:
  replicas: 1
```

## Quick Deploy

```bash
# Clean install
./clean-reinstall.sh

# Manual deploy
./deploy-olm.sh
```

## Verification

```bash
# Check operator status
kubectl get csv,subscription,operatorgroup -n default

# Check CRD
kubectl get crd k8soperators.apps.mydomain.com

# Check managed resources
kubectl get k8soperators,deployments,services -n default
```

## Key Files

- `api/v1alpha1/k8soperator_types.go` - CRD schema definition
- `config/crd/bases/` - Generated CRD manifests
- `config/manifests/bases/k8soperator.clusterserviceversion.yaml` - CSV template
- `bundle/` - OLM bundle artifacts
- `catalog/` - Catalog index configuration

## Cleanup

```bash
kubectl delete subscription k8soperator-subscription -n default
kubectl delete catalogsource k8soperator-catalog -n olm
```

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Author

Vasudev Chavan