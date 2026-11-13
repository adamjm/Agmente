# Project runtime with Oh My Pi (omp) as the ACP agent. Built on the Bob image so git and the tools stay the same.
# omp 18.2.3 needs Bun (package engines: bun >= 1.3.14), so Bun is installed first and pinned.
# Build (Mac, Apple container CLI; --dns is the Mac's own resolver, see D-081):
#   container build --dns 192.168.86.1 -t localhost/acpcode-omp:18.2.3 -f deploy/omp-project.Containerfile deploy
# omp's agent directory (models.yml, config.yml, caches) is baked into the image at /opt/omp-agent, because the
# gateway mounts the project home over $HOME. Sessions stay in the project home (PI_CODING_AGENT_SESSION_DIR), so
# an idle reload can still load them.
FROM localhost/acpcode-bob:2.0.9-tools1
USER root
ENV BUN_INSTALL=/opt/bun
ENV PATH=/opt/bun/bin:$PATH
RUN npm install -g --save-exact bun@1.3.14 \
 && bun add -g --exact @oh-my-pi/pi-coding-agent@18.2.3 \
 && npm cache clean --force \
 && chmod -R a+rX /opt/bun \
 && ln -s /opt/bun/bin/omp /usr/local/bin/omp \
 && omp --version
COPY omp-config/ /opt/omp-agent/
RUN chmod -R a+rwX /opt/omp-agent
ENV PI_CODING_AGENT_DIR=/opt/omp-agent
ENV PI_CODING_AGENT_SESSION_DIR=/home/bob/.omp/sessions
USER bob
ENV HOME=/home/bob
WORKDIR /work
