FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o server main.go

FROM alpine:3.20
COPY --from=builder /app/server /server
# Unprivileged: the server listens on $PORT (above 1024) and touches no files.
USER 65534:65534
ENTRYPOINT ["/server"]
