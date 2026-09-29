FROM node@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6

ENV NODE_ENV=production

LABEL org.opencontainers.image.source="https://github.com/Jes-lo/kubernetes-gitops-platform"
LABEL org.opencontainers.image.title="kubernetes-gitops-platform-demo-api"
LABEL org.opencontainers.image.description="Demo API workload for the Kubernetes GitOps Platform portfolio project"

WORKDIR /app

COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src

USER node

EXPOSE 3000

CMD ["node", "src/server.js"]
