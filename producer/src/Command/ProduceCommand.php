<?php

namespace App\Command;

use App\Message\FederationMessage;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;
use Symfony\Component\Messenger\MessageBusInterface;

#[AsCommand(
    name: 'app:produce',
    description: 'Produce a message and push it to RabbitMQ #1 via federation.in exchange',
)]
class ProduceCommand extends Command
{
    public function __construct(
        private readonly MessageBusInterface $bus,
    ) {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addArgument('text', InputArgument::REQUIRED, 'The text to send via federation');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $text = $input->getArgument('text');

        $message = new FederationMessage($text, (new \DateTimeImmutable())->format(\DateTimeInterface::ATOM));
        $this->bus->dispatch($message);

        $io->success(sprintf(
            'Dispatched message to federation.in exchange: "%s" (created at %s)',
            $text,
            $message->createdAt,
        ));

        return Command::SUCCESS;
    }
}