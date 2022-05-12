# Build Stage
FROM --platform=linux/amd64 ubuntu:20.04 as builder

## Install build dependencies.
RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y vim less man wget tar git gzip unzip make cmake software-properties-common curl
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y zlib1g-dev libbz2-dev libssl-dev

ADD . /dmg2img
WORKDIR /dmg2img
RUN make -j8 dmg2img
