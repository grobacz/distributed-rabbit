FROM php:8.3-cli-alpine

RUN apk add --no-cache linux-headers $PHPIZE_DEPS rabbitmq-c-dev \
    && pecl install amqp-2.1.2 \
    && docker-php-ext-enable amqp \
    && apk del $PHPIZE_DEPS

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app
COPY . .

RUN composer install --no-dev --optimize-autoloader --no-interaction --ignore-platform-reqs

ENTRYPOINT ["php", "bin/console"]
CMD ["about"]