# Gearman Proxy

Relay gearman jobs from one host/queue to other gearman servers queues

Its main purpose is to be used with Naemons Mod-Gearman addon, but you
can relay any job.

## What

Proxy Gearman Jobs from one jobserver to another jobserver. This could
be handy, when you have a worker in a remote net and only push is
allowed.

Mod-Gearman <-> Gearmand <-> Gearman-Proxy <--|--> Gearmand <-> Worker

Instead of the Worker polling from the master gearmand, it can now
poll the jobs from a local jobserver which gets fed by the
Gearman-Proxy.

## Usage

  %> gearman_proxy.pl --config=./gearman_proxy.cfg --logfile=stdout --debug

## License

GearmanProxy is Copyright (c) 2009-2020 by Sven Nierlein.
This is free software; you can redistribute it and/or modify it under the
same terms as the Perl5 programming language system itself.

