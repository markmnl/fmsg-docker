#!/bin/sh
set -e

: "${FMSG_DOMAIN:?FMSG_DOMAIN is required}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required}"

FMSGD_DOMAIN="fmsg.${FMSG_DOMAIN}"
WEBAPI_DOMAIN="fmsgapi.${FMSG_DOMAIN}"

# Skip issuance if both certificates already exist
if [ -d "/etc/letsencrypt/live/${FMSGD_DOMAIN}" ] && \
   [ -d "/etc/letsencrypt/live/${WEBAPI_DOMAIN}" ]; then
  echo "Certificates for ${FMSGD_DOMAIN} and ${WEBAPI_DOMAIN} already exist, skipping."
  exit 0
fi

echo "Requesting certificate for ${FMSGD_DOMAIN} ..."
certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email "${CERTBOT_EMAIL}" \
  -d "${FMSGD_DOMAIN}"

echo "Requesting certificate for ${WEBAPI_DOMAIN} ..."
certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email "${CERTBOT_EMAIL}" \
  -d "${WEBAPI_DOMAIN}"

# certbot creates private keys as root:root 0600.  The application
# containers run as an unprivileged user so the keys must be readable.
chmod 0644 "/etc/letsencrypt/live/${FMSGD_DOMAIN}/privkey.pem" \
           "/etc/letsencrypt/live/${WEBAPI_DOMAIN}/privkey.pem"
chmod 0755 /etc/letsencrypt/live \
           /etc/letsencrypt/archive \
           "/etc/letsencrypt/live/${FMSGD_DOMAIN}" \
           "/etc/letsencrypt/live/${WEBAPI_DOMAIN}" \
           "/etc/letsencrypt/archive/${FMSGD_DOMAIN}" \
           "/etc/letsencrypt/archive/${WEBAPI_DOMAIN}"

echo "Certificates issued successfully."
