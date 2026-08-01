#!/usr/bin/env bash
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-minikube}"

read -r -p "This will run 'minikube delete --profile $PROFILE', destroying the cluster. Continue? [y/N] " ans
case "$ans" in
  [yY]|[yY][eE][sS]) ;;
  *) echo "Aborted."; exit 1 ;;
esac

minikube delete --profile "$PROFILE"
