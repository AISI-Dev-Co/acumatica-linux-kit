FROM dockurr/windows@sha256:20b398ab935465f97ec8ab06489f7a85a5ad58e74e036ce66cc3c9172e7dbea8

RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		netcat-openbsd \
		openssh-client \
		socat \
		sshpass \
	&& rm -rf /var/lib/apt/lists/*
