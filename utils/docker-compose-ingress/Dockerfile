FROM nginx:1.29-bookworm@sha256:8adbdcb969e2676478ee2c7ad333956f0c8e0e4c5a7463f4611d7a2e7a7ff5dc
ENV FILE_SIZE_LIMIT_MB=100
ENV DOMAIN=localhost

RUN mkdir -p /var/nginx /var/www/certbot
COPY utils/docker-compose-ingress/nginx/templates /etc/nginx/templates
COPY utils/docker-compose-ingress/nginx/conf/mime.types /etc/nginx/mime.types
COPY utils/docker-compose-ingress/docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh

ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
CMD ["nginx", "-g", "daemon off;"]

EXPOSE 8080 8443
