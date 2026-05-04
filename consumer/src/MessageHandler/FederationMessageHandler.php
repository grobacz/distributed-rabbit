<?php

namespace App\MessageHandler;

use App\Message\FederationMessage;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
class FederationMessageHandler
{
    public function __invoke(FederationMessage $message): void
    {
        $line = sprintf(
            "[%s] Consumed federated message: %s (originally created at %s)\n",
            date('c'),
            $message->text,
            $message->createdAt,
        );

        file_put_contents('/app/var/log/consumed.log', $line, FILE_APPEND | LOCK_EX);
    }
}