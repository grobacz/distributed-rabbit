<?php

namespace App\Message;

class FederationMessage
{
    public function __construct(
        public readonly string $text,
        public readonly string $createdAt = '',
    ) {
    }
}