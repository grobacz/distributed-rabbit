.PHONY: up down logs test reset produce consume

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

produce:
	@read -p "Enter message text: " text; \
	docker compose run --rm producer app:produce "$$text"

consume:
	docker compose run --rm consumer messenger:consume consumer -vv

consume-log:
	docker run --rm --entrypoint cat -v distributed-rabbit_consumer-log:/app/var/log distributed-rabbit-consumer /app/var/log/consumed.log 2>/dev/null || echo "No log file yet."

test:
	@echo "Publishing test message to RabbitMQ #1..."
	docker compose run --rm producer app:produce "federation test $$(date +%H:%M:%S)"
	@echo ""
	@echo "Consuming from RabbitMQ #2..."
	@timeout 10 docker compose run --rm consumer messenger:consume consumer -vv || true
	@echo ""
	@echo "=== Consumed log ==="
	docker run --rm --entrypoint cat -v distributed-rabbit_consumer-log:/app/var/log distributed-rabbit-consumer /app/var/log/consumed.log 2>/dev/null || echo "(no log yet)"

reset: down
	docker compose down -v
	docker compose build