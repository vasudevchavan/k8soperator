#!/bin/bash
set -euo pipefail

# ==============================================
# K8s Operator OLM Deployment Script
# ==============================================

# Configuration
IMG="docker.io/vasudevdchavan/k8soperator"
VERSION="0.1.3"
OPERATOR_NAME="k8soperator"
NAMESPACE="default"

# Derived variables
BUNDLE_IMG="${IMG}-bundle:${VERSION}"
INDEX_IMG="${IMG}-index:${VERSION}"

echo "🚀 Starting OLM deployment for ${OPERATOR_NAME} v${VERSION}"

# Step 1: Check prerequisites
echo "🔧 Checking prerequisites..."
command -v operator-sdk >/dev/null 2>&1 || { echo "❌ operator-sdk not found"; exit 1; }
command -v opm >/dev/null 2>&1 || { echo "❌ opm not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "❌ docker not found"; exit 1; }

# Check if OLM is installed
if ! kubectl get crd clusterserviceversions.operators.coreos.com >/dev/null 2>&1; then
    echo "❌ OLM not installed. Please install OLM first:"
    echo "   curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.28.0/install.sh | bash -s v0.28.0"
    exit 1
fi

echo "✅ All prerequisites met"

# Step 2: Build and push operator image
echo "🔨 Building operator image..."
export IMG VERSION OPERATOR_NAME BUNDLE_IMG INDEX_IMG
make build docker-build docker-push

# Step 3: Generate and push bundle
echo "📦 Generating OLM bundle..."
make bundle bundle-build bundle-push

# Step 4: Generate and push catalog
echo "📚 Building catalog index..."
make catalog-render catalog-build catalog-push

# Step 5: Clean up existing installation
echo "🧹 Cleaning up existing installation..."
kubectl delete subscription ${OPERATOR_NAME}-subscription -n ${NAMESPACE} --ignore-not-found=true
kubectl delete csv -l operators.coreos.com/${OPERATOR_NAME}.${NAMESPACE} -n ${NAMESPACE} --ignore-not-found=true
kubectl delete catalogsource ${OPERATOR_NAME}-catalog -n olm --ignore-not-found=true

# Wait for cleanup
sleep 5

# Step 6: Create CatalogSource
echo "📋 Creating CatalogSource..."
make generate-catalogsource
kubectl apply -f catalogsource.yaml

# Step 7: Wait for catalog to be ready
echo "⏳ Waiting for catalog to be ready..."
kubectl wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY catalogsource/${OPERATOR_NAME}-catalog -n olm --timeout=180s

# Step 8: Create OperatorGroup
echo "👥 Creating OperatorGroup..."
cat <<EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${OPERATOR_NAME}-operatorgroup
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
EOF

# Step 9: Create Subscription
echo "📝 Creating Subscription..."
cat <<EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR_NAME}-subscription
  namespace: ${NAMESPACE}
spec:
  channel: stable
  name: ${OPERATOR_NAME}
  source: ${OPERATOR_NAME}-catalog
  sourceNamespace: olm
EOF

# Step 10: Wait for CSV to be ready
echo "⏳ Waiting for ClusterServiceVersion to be ready..."
timeout=180
while [ $timeout -gt 0 ]; do
    if kubectl get csv -n ${NAMESPACE} | grep -q "Succeeded"; then
        echo "✅ CSV is ready"
        break
    fi
    echo "Waiting for CSV... ($timeout seconds remaining)"
    sleep 5
    timeout=$((timeout - 5))
done

if [ $timeout -le 0 ]; then
    echo "❌ Timeout waiting for CSV to be ready"
    exit 1
fi

# Step 11: Wait for controller manager to be ready
echo "⏳ Waiting for controller manager to be ready..."
kubectl wait --for=condition=Ready pod -l control-plane=controller-manager -n ${NAMESPACE} --timeout=120s

# Step 12: Wait for CRD to be available
echo "⏳ Waiting for K8soperator CRD to be available..."
timeout=60
while [ $timeout -gt 0 ]; do
    if kubectl get crd k8soperators.apps.mydomain.com >/dev/null 2>&1; then
        echo "✅ CRD is available"
        break
    fi
    echo "Waiting for CRD... ($timeout seconds remaining)"
    sleep 5
    timeout=$((timeout - 5))
done

if [ $timeout -le 0 ]; then
    echo "❌ CRD not created by operator. This indicates a bundle configuration issue."
    echo "🔍 Debugging information:"
    echo "CSV status:"
    kubectl get csv -n ${NAMESPACE} -o wide
    echo ""
    echo "CSV CRD definitions:"
    kubectl get csv -n ${NAMESPACE} -o jsonpath='{.items[0].spec.customresourcedefinitions}' | jq . 2>/dev/null || echo "No CRDs found in CSV spec"
    echo ""
    echo "Available CRDs:"
    kubectl get crd | grep -i k8s || echo "No k8s-related CRDs found"
    echo ""
    echo "❌ Please check your bundle configuration. The CRD should be defined in the CSV."
    exit 1
fi

# Step 13: Create sample CR
echo "📄 Creating sample K8soperator CR..."
cat <<EOF | kubectl apply -f -
apiVersion: apps.mydomain.com/v1alpha1
kind: K8soperator
metadata:
  name: ${OPERATOR_NAME}-sample
  namespace: ${NAMESPACE}
spec:
  replicas: 1
EOF

# Step 14: Verify deployment
echo "🔍 Verifying deployment..."
sleep 10

echo "📊 Deployment Status:"
echo "===================="
kubectl get csv -n ${NAMESPACE}
echo ""
kubectl get pods -n ${NAMESPACE}
echo ""
kubectl get k8soperators -n ${NAMESPACE}
echo ""

# Check if managed deployments are created
if kubectl get deployment web-application -n ${NAMESPACE} >/dev/null 2>&1 && \
   kubectl get deployment data-db -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "✅ Managed deployments created successfully"
    kubectl get deployments -n ${NAMESPACE}
else
    echo "⚠️  Managed deployments not found. Check controller logs:"
    kubectl logs -l control-plane=controller-manager -n ${NAMESPACE} --tail=20
fi

echo ""
echo "🎉 OLM deployment completed successfully!"
echo ""
echo "📋 Next steps:"
echo "   • Check operator status: kubectl get csv -n ${NAMESPACE}"
echo "   • View CRDs: kubectl get crd | grep k8soperator"
echo "   • View managed resources: kubectl get k8soperators,deployments,services -n ${NAMESPACE}"
echo "   • Check controller logs: kubectl logs -l control-plane=controller-manager -n ${NAMESPACE}"
echo "   • Delete sample CR: kubectl delete k8soperator ${OPERATOR_NAME}-sample -n ${NAMESPACE}"
echo ""
echo "🗑️  To uninstall:"
echo "   kubectl delete subscription ${OPERATOR_NAME}-subscription -n ${NAMESPACE}"
echo "   kubectl delete catalogsource ${OPERATOR_NAME}-catalog -n olm"