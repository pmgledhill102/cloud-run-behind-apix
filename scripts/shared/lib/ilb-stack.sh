#!/usr/bin/env bash
#
# ilb-stack.sh — Create/delete internal HTTPS load balancer in workloads-vpc
#
# Creates: ILB IP, Serverless NEG, backend service, URL map, self-signed cert,
# target HTTPS proxy, forwarding rule.
#
# Used by options 1 (VPN) and 4 (PSC Service Attachment).
#
# Source this after env.sh + helpers.sh:
#   source "${SHARED_DIR}/lib/ilb-stack.sh"
#

create_ilb_stack() {
  echo "--- Create ILB stack (workloads-vpc) ---"

  # Reserve ILB IP
  if resource_exists gcloud compute addresses describe "ilb-ip-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Address 'ilb-ip-workloads' already exists, skipping."
  else
    gcloud compute addresses create "ilb-ip-workloads" \
      --region="${REGION}" \
      --subnet=compute-workloads \
      --addresses=10.100.0.10 \
      --project="${PROJECT_ID}"
    echo "Address 'ilb-ip-workloads' (10.100.0.10) reserved."
  fi

  # Serverless NEG
  if resource_exists gcloud compute network-endpoint-groups describe "neg-cr-hello" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "NEG 'neg-cr-hello' already exists, skipping."
  else
    gcloud compute network-endpoint-groups create "neg-cr-hello" \
      --region="${REGION}" \
      --network-endpoint-type=serverless \
      --cloud-run-service=cr-hello \
      --project="${PROJECT_ID}"
    echo "NEG 'neg-cr-hello' created."
  fi

  # Backend service
  if resource_exists gcloud compute backend-services describe "backend-cr-hello" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Backend service 'backend-cr-hello' already exists, skipping."
  else
    gcloud compute backend-services create "backend-cr-hello" \
      --region="${REGION}" \
      --load-balancing-scheme=INTERNAL_MANAGED \
      --protocol=HTTPS \
      --project="${PROJECT_ID}"
    gcloud compute backend-services add-backend "backend-cr-hello" \
      --region="${REGION}" \
      --network-endpoint-group=neg-cr-hello \
      --network-endpoint-group-region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "Backend service 'backend-cr-hello' created with NEG backend."
  fi

  # URL map
  if resource_exists gcloud compute url-maps describe "urlmap-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "URL map 'urlmap-workloads' already exists, skipping."
  else
    gcloud compute url-maps create "urlmap-workloads" \
      --region="${REGION}" \
      --default-service=backend-cr-hello \
      --project="${PROJECT_ID}"
    echo "URL map 'urlmap-workloads' created."
  fi

  # Self-signed SSL certificate
  if resource_exists gcloud compute ssl-certificates describe "cert-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "SSL certificate 'cert-workloads' already exists, skipping."
  else
    CERT_DIR="$(mktemp -d)"
    openssl req -x509 -nodes -days 365 \
      -newkey rsa:2048 \
      -keyout "${CERT_DIR}/key.pem" \
      -out "${CERT_DIR}/cert.pem" \
      -subj "/CN=api.internal.example.com" 2>/dev/null
    gcloud compute ssl-certificates create "cert-workloads" \
      --region="${REGION}" \
      --certificate="${CERT_DIR}/cert.pem" \
      --private-key="${CERT_DIR}/key.pem" \
      --project="${PROJECT_ID}"
    rm -rf "${CERT_DIR}"
    echo "SSL certificate 'cert-workloads' created."
  fi

  # Target HTTPS proxy
  if resource_exists gcloud compute target-https-proxies describe "proxy-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Target HTTPS proxy 'proxy-workloads' already exists, skipping."
  else
    gcloud compute target-https-proxies create "proxy-workloads" \
      --region="${REGION}" \
      --url-map=urlmap-workloads \
      --ssl-certificates=cert-workloads \
      --project="${PROJECT_ID}"
    echo "Target HTTPS proxy 'proxy-workloads' created."
  fi

  # Forwarding rule
  if resource_exists gcloud compute forwarding-rules describe "fwd-rule-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Forwarding rule 'fwd-rule-workloads' already exists, skipping."
  else
    gcloud compute forwarding-rules create "fwd-rule-workloads" \
      --region="${REGION}" \
      --load-balancing-scheme=INTERNAL_MANAGED \
      --network=workloads-vpc \
      --subnet=compute-workloads \
      --address=ilb-ip-workloads \
      --ports=443 \
      --target-https-proxy=proxy-workloads \
      --target-https-proxy-region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "Forwarding rule 'fwd-rule-workloads' created."
  fi

  echo "ILB stack ready (10.100.0.10:443)."
}

delete_ilb_stack() {
  echo "--- Delete ILB stack ---"

  # Forwarding rule
  if resource_exists gcloud compute forwarding-rules describe "fwd-rule-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute forwarding-rules delete "fwd-rule-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Forwarding rule 'fwd-rule-workloads' deleted."
  else
    echo "Forwarding rule 'fwd-rule-workloads' does not exist, skipping."
  fi

  # Target HTTPS proxy
  if resource_exists gcloud compute target-https-proxies describe "proxy-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute target-https-proxies delete "proxy-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Target HTTPS proxy 'proxy-workloads' deleted."
  else
    echo "Target HTTPS proxy 'proxy-workloads' does not exist, skipping."
  fi

  # SSL certificate
  if resource_exists gcloud compute ssl-certificates describe "cert-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute ssl-certificates delete "cert-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "SSL certificate 'cert-workloads' deleted."
  else
    echo "SSL certificate 'cert-workloads' does not exist, skipping."
  fi

  # URL map
  if resource_exists gcloud compute url-maps describe "urlmap-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute url-maps delete "urlmap-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "URL map 'urlmap-workloads' deleted."
  else
    echo "URL map 'urlmap-workloads' does not exist, skipping."
  fi

  # Backend service
  if resource_exists gcloud compute backend-services describe "backend-cr-hello" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute backend-services delete "backend-cr-hello" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Backend service 'backend-cr-hello' deleted."
  else
    echo "Backend service 'backend-cr-hello' does not exist, skipping."
  fi

  # Serverless NEG
  if resource_exists gcloud compute network-endpoint-groups describe "neg-cr-hello" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute network-endpoint-groups delete "neg-cr-hello" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "NEG 'neg-cr-hello' deleted."
  else
    echo "NEG 'neg-cr-hello' does not exist, skipping."
  fi

  # ILB IP
  if resource_exists gcloud compute addresses describe "ilb-ip-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute addresses delete "ilb-ip-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Address 'ilb-ip-workloads' deleted."
  else
    echo "Address 'ilb-ip-workloads' does not exist, skipping."
  fi
}
