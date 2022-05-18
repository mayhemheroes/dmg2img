FROM --platform=linux/amd64 ubuntu:20.04

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential libz-dev libbz2-dev libssl-dev

ADD . /dmg2img
WORKDIR /dmg2img
RUN make -j8 dmg2img
