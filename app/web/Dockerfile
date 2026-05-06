FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Serve with nginx — minimal, non-root
FROM nginx:1.25-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

# nginx needs to write to these directories
RUN chown -R nginx:nginx /var/cache/nginx /var/log/nginx /etc/nginx/conf.d \
 && chown -R nginx:nginx /usr/share/nginx/html

USER nginx
EXPOSE 80
HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
  CMD wget -qO- http://localhost:80 || exit 1
