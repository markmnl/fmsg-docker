# fmsg-mcp: MCP server over the fmsg Web API, served as Streamable HTTP.
# Each MCP client presents its own fmsg API key as a bearer token.
FROM node:22-alpine

ARG FMSG_MCP_REF=latest
ARG CACHEBUST

RUN npm install -g "@markmnl/fmsg-mcp@${FMSG_MCP_REF}" && npm cache clean --force

USER node

EXPOSE 8765

ENTRYPOINT ["fmsg-mcp"]
CMD ["--http", "0.0.0.0:8765"]
