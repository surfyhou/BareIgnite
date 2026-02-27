FROM rockylinux:9

RUN dnf install -y epel-release && \
    dnf install -y python3 python3-pip \
    xorriso mkisofs syslinux dosfstools parted \
    curl wget git && \
    dnf clean all

WORKDIR /app
COPY app/ /app/
COPY data/ /app/data/

RUN pip3 install --no-cache-dir fastapi uvicorn[standard] pyyaml aiofiles aiohttp

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
