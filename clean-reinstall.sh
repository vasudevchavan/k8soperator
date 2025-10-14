#!/bin/bash
set -euo pipefail

# Configuration
OPERATOR_NAME="k8soperator"
NAMESPACE="default"

echo "🧹 Cleaning up existing operator installation..."

# Remove Custom Resources
kubectl delete k8soperator --all -n ${NAMESPACE} --ignore-not-found=true 2>/dev/null || true

# Remove Subscription
kubectl delete subscription ${OPERATOR_NAME}-subscription -n ${NAMESPACE} --ignore-not-found=true

# Remove OperatorGroup
kubectl delete operatorgroup ${OPERATOR_NAME}-operatorgroup -n ${NAMESPACE} --ignore-not-found=true

# Remove CSV
kubectl delete csv -l operators.coreos.com/${OPERATOR_NAME}.${NAMESPACE} -n ${NAMESPACE} --ignore-not-found=true

# Remove CatalogSource
kubectl delete catalogsource ${OPERATOR_NAME}-catalog -n olm --ignore-not-found=true

# Remove CRDs (if manually installed)
kubectl delete crd k8soperators.apps.mydomain.com --ignore-not-found=true

# Remove managed resources
kubectl delete deployment web-application data-db -n ${NAMESPACE} --ignore-not-found=true

echo "✅ Cleanup completed"
echo "⏳ Waiting 10 seconds for cleanup to propagate..."
sleep 10

echo "🚀 Starting fresh operator installation..."
./deploy-olm.sh