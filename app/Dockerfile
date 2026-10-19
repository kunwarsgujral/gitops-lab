FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
# Run as a non-root user.
RUN useradd --system --uid 10001 appuser
USER 10001
EXPOSE 8080
CMD ["python", "app.py"]
