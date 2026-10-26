FROM nginx:1.30-trixie@sha256:a7675fcee220f59b4a99f7098c06a0d5d999c2c0ee37c0211efb780536e5cb20
ENV FILE_SIZE_LIMIT_MB=100
ENV DOMAIN=localhost

RUN mkdir -p /var/nginx /var/www/certbot
COPY utils/docker-compose-ingress/nginx/templates /etc/nginx/templates
COPY utils/docker-compose-ingress/nginx/conf/mime.types /etc/nginx/mime.types
COPY utils/docker-compose-ingress/docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh

ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
CMD ["nginx", "-g", "daemon off;"]

EXPOSE 8080 8443
