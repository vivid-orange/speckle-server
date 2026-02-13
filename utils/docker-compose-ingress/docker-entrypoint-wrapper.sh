#!/bin/sh
# If DOMAIN_ALIAS is not set, replace the alias template with an empty config
# so the include directive in nginx.conf doesn't fail.
if [ -z "$DOMAIN_ALIAS" ]; then
  echo "# DOMAIN_ALIAS not set - alias redirect disabled" > /etc/nginx/nginx-alias.conf
  rm -f /etc/nginx/templates/nginx-alias.conf.template
fi

exec /docker-entrypoint.sh "$@"
