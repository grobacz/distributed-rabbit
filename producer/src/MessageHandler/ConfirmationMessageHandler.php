<?php

namespace App\MessageHandler;

use App\Message\ConfirmationMessage;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
class ConfirmationMessageHandler
{
    public function __invoke(ConfirmationMessage $message): void
    {
        $line = sprintf(
            "[%s] Received confirmation: %s\n",
            date('c'),
            $message->text,
        );

        file_put_contents('/app/var/log/confirmed.log', $line, FILE_APPEND | LOCK_EX);
    }
}
