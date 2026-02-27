FROM rockylinux:9

RUN dnf install -y epel-release && \
    dnf install -y --allowerasing python3 python3-pip \
    xorriso genisoimage dosfstools parted \
    curl wget git && \
    dnf clean all

WORKDIR /app
COPY app/ /app/
COPY data/ /app/data/

RUN pip3 install --no-cache-dir --require-hashes=false fastapi uvicorn pyyaml aiofiles aiohttp pydantic httptools

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
