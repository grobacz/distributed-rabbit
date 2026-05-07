<?php

namespace App\MessageHandler;

use App\Message\ConfirmationMessage;
use App\Message\FederationMessage;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Symfony\Component\Messenger\MessageBusInterface;

#[AsMessageHandler]
class FederationMessageHandler
{
    public function __construct(
        private readonly MessageBusInterface $bus,
    ) {
    }

    public function __invoke(FederationMessage $message): void
    {
        $line = sprintf(
            "[%s] Consumed federated message: %s (originally created at %s)\n",
            date('c'),
            $message->text,
            $message->createdAt,
        );

        file_put_contents('/app/var/log/consumed.log', $line, FILE_APPEND | LOCK_EX);

        $confirmation = new ConfirmationMessage(
            text: sprintf('Confirmed: "%s" processed at %s', $message->text, date('c')),
            processedAt: date('c'),
        );

        $this->bus->dispatch($confirmation);
    }
}
