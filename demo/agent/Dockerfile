FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir PyJWT
COPY main.py .
USER 1001
ENTRYPOINT ["python3", "main.py"]
