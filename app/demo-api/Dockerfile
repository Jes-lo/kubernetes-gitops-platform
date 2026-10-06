FROM node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20

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
