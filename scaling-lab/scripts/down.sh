#!/usr/bin/env bash
# Deletes the whole lab cluster (nothing else on your machine is touched).
set -euo pipefail
kind delete cluster --name scaling
