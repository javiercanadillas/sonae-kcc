# Build stage
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Copy go mod and sum files
COPY go.mod ./
# Since I don't have go.sum yet, it will be generated if I run go mod tidy
# but for simplicity I'll just copy what exists and run tidy
RUN go mod tidy

COPY . .

RUN go build -o main .

# Final stage
FROM gcr.io/distroless/static-debian12

WORKDIR /

COPY --from=builder /app/main .

EXPOSE 8080

USER nonroot:nonroot

CMD ["./main"]
