#!/bin/bash
set -xeuo pipefail

# -----------------------------
# Configurable Variables
# -----------------------------
IMG="docker.io/vasudevdchavan/k8soperator"   # Manager image
VERSION="0.1.4"                              # Bundle/Index version
OPERATOR_NAME="k8soperator"                  # Operator name

# Derived images
BUNDLE_IMG="${IMG}-bundle:${VERSION}"
INDEX_IMG="${IMG}-index:${VERSION}"
CATALOG_DIR="catalog"

# Export variables for make
export IMG VERSION OPERATOR_NAME BUNDLE_IMG INDEX_IMG

echo "🔧 Checking for required tools..."
make check-tools

echo "🔨 Building operator binary..."
make build

echo "🐳 Building & 📤 Push Operator Docker image: $IMG"
make docker-build docker-push

echo "📦 Generating Operator Bundle..."
make bundle

echo "🐳 Building & 📤 Push Bundle Docker image: $BUNDLE_IMG"
make bundle-build bundle-push


echo "📚 Building Index catalog"
make catalog-render

echo "🐳 Building & 📤 Push Index Docker image: $INDEX_IMG"
make catalog-build catalog-push

echo "📝 Generating CatalogSource YAML..."
make generate-catalogsource

echo ""
echo "✅ Operator build and catalog process complete!"
echo "📄 Apply CatalogSource with:"
echo "   kubectl apply -f catalogsource.yaml"
