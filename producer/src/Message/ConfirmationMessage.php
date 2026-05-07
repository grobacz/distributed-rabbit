<?php

namespace App\Message;

class ConfirmationMessage
{
    public function __construct(
        public readonly string $text,
        public readonly string $processedAt = '',
    ) {
    }
}
