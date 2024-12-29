FROM golang:1.23-alpine AS builder

RUN apk update && apk add --no-cache git

WORKDIR /obfs4proxy
RUN git clone https://github.com/Yawning/obfs4.git .

WORKDIR /tailscale
RUN git clone https://github.com/tailscale/tailscale.git . && git checkout v1.78.3

WORKDIR /singbox
RUN git clone https://github.com/SagerNet/sing-box.git . && git checkout v1.11.0-beta.17

WORKDIR /mihomo
RUN git clone -b Alpha https://github.com/MetaCubeX/mihomo.git . && git checkout v1.19.0

WORKDIR /easymosdns
RUN git clone https://github.com/signingup/easymosdns.git . && rm -rf .git

WORKDIR /mosdns
RUN git clone https://github.com/pmkol/mosdns.git .

#build mosdns
WORKDIR /mosdns

RUN go mod download
RUN go build -trimpath -ldflags '-w -s -buildid=' -o /go/bin/mosdns

#build mihomo
WORKDIR /mihomo

RUN go mod download

RUN VERSION=$(git rev-parse --short HEAD) && \
    BUILDTIME=$(date -u) && \
    CGO_ENABLED=0 && \
    go build -tags with_gvisor -trimpath -ldflags '-X "github.com/metacubex/mihomo/constant.Version=${VERSION}" \
		-X "github.com/metacubex/mihomo/constant.BuildTime=${BUILDTIME}" \
		-w -s -buildid=' -o /go/bin/mihomo

#build obfs4
WORKDIR /obfs4proxy

RUN go build -trimpath -ldflags '-w -s -buildid=' -o /go/bin/obfs4proxy ./obfs4proxy

#build tailscale
WORKDIR /tailscale

RUN go mod download

# Pre-build some stuff before the following COPY line invalidates the Docker cache.
RUN go install \
    github.com/aws/aws-sdk-go-v2/aws \
    github.com/aws/aws-sdk-go-v2/config \
    gvisor.dev/gvisor/pkg/tcpip/adapters/gonet \
    gvisor.dev/gvisor/pkg/tcpip/stack \
    golang.org/x/crypto/ssh \
    golang.org/x/crypto/acme \
    github.com/coder/websocket \
    github.com/mdlayher/netlink

# see build_docker.sh
ARG VERSION_LONG=""
ENV VERSION_LONG=$VERSION_LONG
ARG VERSION_SHORT=""
ENV VERSION_SHORT=$VERSION_SHORT
ARG VERSION_GIT_HASH=""
ENV VERSION_GIT_HASH=$VERSION_GIT_HASH
ARG TARGETARCH

RUN GOARCH=$TARGETARCH go install -trimpath -ldflags="\
      -s -w -buildid= \
      -X tailscale.com/version.longStamp=$VERSION_LONG \
      -X tailscale.com/version.shortStamp=$VERSION_SHORT \
      -X tailscale.com/version.gitCommitStamp=$VERSION_GIT_HASH" \
      -v ./cmd/tailscale ./cmd/tailscaled ./cmd/containerboot

#build singbox
WORKDIR /singbox

ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG GOPROXY=""
ENV GOPROXY ${GOPROXY}
ENV CGO_ENABLED=1
ENV GOOS=$TARGETOS
ENV GOARCH=$TARGETARCH
RUN set -ex \
    && apk add build-base linux-headers\
    && export COMMIT=$(git rev-parse --short HEAD) \
    && export VERSION=$(go run ./cmd/internal/read_tag) \
    && go build -v -trimpath -tags \
        "with_gvisor,with_quic,with_dhcp,with_wireguard,with_ech,with_utls,with_reality_server,with_acme,with_clash_api,with_embedded_tor,staticOpenssl,staticZlib,staticLibevent" \
        -o /go/bin/sing-box \
        -ldflags "-X \"github.com/sagernet/sing-box/constant.Version=$VERSION\" -s -w -buildid=" \
        ./cmd/sing-box

FROM alpine:latest

RUN apk add --no-cache git rsync sed tzdata grep dcron openrc bash curl bc keepalived tcptraceroute radvd nano wget ca-certificates tor iptables ip6tables openssh openssh-keygen jq iproute2 net-tools bind-tools

COPY --from=builder /go/bin/. /usr/local/bin/
COPY --from=builder /easymosdns /etc/mosdns

# For compat with the previous run.sh, although ideally you should be
# using build_docker.sh which sets an entrypoint for the image.
RUN mkdir /tailscale && ln -s /usr/local/bin/containerboot /tailscale/run.sh

RUN wget http://www.vdberg.org/~richard/tcpping -O /usr/bin/tcpping
RUN chmod 755 /usr/bin/tcpping

RUN mkdir -p /run/radvd

RUN mkdir -p /var/run/sshd
# Configure SSH
RUN ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa
#RUN ssh-keygen -f /etc/ssh/ssh_host_dsa_key -N '' -t dsa
RUN mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh

COPY ./entrypoint.sh /usr/bin/
COPY ./sshd_config /etc/ssh/

RUN chmod +x /usr/bin/entrypoint.sh

ENV TZ=UTC
RUN cp /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

ENV ROOT_PASSWORD=
ENV ROOT_PASSWORD_LOGIN=false
ENV SSH_DIR=
ENV TS_SOCKS5_PORT=1055

EXPOSE 22
EXPOSE 53
EXPOSE 5353
EXPOSE 9080

CMD ["/usr/bin/entrypoint.sh"]
