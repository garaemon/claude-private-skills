FROM python:3.12-slim

RUN groupadd --system --gid 1000 checker \
    && useradd --system --uid 1000 --gid 1000 --shell /usr/sbin/nologin checker

WORKDIR /app

COPY check_updates.py /app/check_updates.py
RUN chmod 0755 /app/check_updates.py

USER checker

ENV WORKSPACE=/workspace

ENTRYPOINT ["/app/check_updates.py"]
