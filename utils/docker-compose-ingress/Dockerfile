FROM nginx:1.25-bookworm@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c
ENV FILE_SIZE_LIMIT_MB=100
ENV DOMAIN=localhost

RUN mkdir -p /var/nginx /var/www/certbot
COPY utils/docker-compose-ingress/nginx/templates /etc/nginx/templates
COPY utils/docker-compose-ingress/nginx/conf/mime.types /etc/nginx/mime.types
COPY utils/docker-compose-ingress/docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh

ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
CMD ["nginx", "-g", "daemon off;"]

EXPOSE 8080 8443
