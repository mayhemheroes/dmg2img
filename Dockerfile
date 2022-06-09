FROM --platform=linux/amd64 ubuntu:20.04 as builder

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential libz-dev libbz2-dev libssl-dev

ADD . /dmg2img
WORKDIR /dmg2img
RUN make -j8 dmg2img

RUN mkdir -p /deps
RUN ldd /dmg2img/dmg2img | tr -s '[:blank:]' '\n' | grep '^/' | xargs -I % sh -c 'cp % /deps;'

FROM ubuntu:20.04 as package

COPY --from=builder /deps /deps
COPY --from=builder /dmg2img/dmg2img /dmg2img/dmg2img
ENV LD_LIBRARY_PATH=/deps
