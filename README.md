# Gearman Proxy

Relay [Gearman](http://gearman.org/) jobs from one host/queue to other Gearman servers queues

Its main purpose is to be used with [Naemons](https://www.naemon.org) [Mod-Gearman](https://mod-gearman.org) addon, but you
can relay any job.

## Purpose

Proxy Gearman Jobs from one jobserver to another jobserver. This is handy when
you have a worker in a remote net and only push is allowed.

Ex.: Network B is not allowed to access the (internal) Gearman daemon in Network A. So you start
a separate Gearman daemon in Network B and forward some queues to that one.

                                                          Network A  |  Network B
                                                                     |
    +-------------+       +------------+       +---------------+     |      +----------+       +-------------+
    |             |       |            |       |               |     |      |          |       |             |
    | Mod-Gearman | +---> |  Gearmand  | <---+ | Gearman-Proxy | +--------> | Gearmand | <---+ | Mod-Gearman |
    |             |       |            |       |               |     |      |          |       |   Worker    |
    +-------------+       +------------+       +---------------+     |      +----------+       +-------------+
                                                                     |
                                                                     |

The arrows indicate the direction of the initial connection.

Instead of the Worker polling from the master Gearman daemon in Network A, it can now
poll the jobs from a local jobserver in Network B which gets fed by the Gearman-Proxy.

Note, you will also have to fetch the check_results queue and push the results back
into the local result queue.

## Usage

    %> gearman_proxy.pl --config=./gearman_proxy.cfg --config=./conf.d --logfile=stdout --debug

## Configuration

Each forward is set as a key/value pair in the $queue variable. In the form:

`$queue->{local_ip:local_port/local_queue} = string|object`.

The remote queue is either a simple string of the form `ip:port/queue`, as in
the simple forward example or an perl hash object as in the complex forward
example.

### Simple Forward

Simple "forward" queues which will be moved to the remote host.

gearman_proxy.cfg:

    $queues->{"127.0.0.1:4730/hostgroup_network_b"} = "192.168.1.33:4730/hostgroup_network_b";

This will forward jobs from the Gearman daemon listening on 127.0.0.1:4730 to a
remote gearman daemon listening on 192.168.1.33:4730. The queue name does not change.

Do not forget to fetch the remote result and put it back into the local result queue.

gearman_proxy.cfg:

    $queues->{"192.168.1.33:4730/check_results"} = "127.0.0.1:4730/check_results";


### Complex Forward

A more complex forward could consist of several (optional) stages:

  - fetch stage: get data from local gearmand daemon
  - decrypt stage: decrypt job data with local password
  - data_callback stage: run callback on job data
  - encrypt stage: encrypt with remote password
  - send stage: send job data to remote gearman daemon

gearman_proxy.cfg:

    $queues->{"127.0.0.1:4730/servicegroup_special"} = {
        "decrypt"       => "local password",   # can be "file:path to password file"
        "encrypt"       => "remote password",  # can be "file:path to password file"
        "remoteQueue"   => "192.168.1.33:4730/servicegroup_special",
        "data_callback" => sub { my($data) = @_; $data =~ s/^result_queue=.*$/result_queue=results_servicegroup_special/gmx; return($data); },
        "async"         => 1, # queue forwards are asynchronous by default, set to 0 to make them synchronous
        "worker"        => 1, # set the number of worker (for synchronous queues only)
    };

See the Queue Options for detailed description.

### Queue Options

#### decrypt

Local password to decrypt Mod-Gearman job package. You can read the password from
a file by specifing: `file:.../path to file`

#### encrypt

Remote password if remote Mod-Gearman worker uses a different password. Is has the same
form as `decrypt`.

#### data_callback

Perl sub callback which can change the job content. Does not have to be inline.
Since the configuration file is evalualted as perl, you can store the callback
in a variable and use that later.

    $callback = sub {
      my($data, $job, $config, $self) = @_;

      # do something with the data, for example, change the result queue
      $data =~ s/^result_queue=.*$/result_queue=results_servicegroup_special/gmx;

      # returned result will be pushed to the remote server
      return($data);
    }

    $queues->{"..."} = {
        ...
        "data_callback" => $callback,
    };

#### remoteQueue

Name of the daemon and queue where to push the job after processing the other stages. The
syntax is `ip:port/queue`.

#### async

Queue forwarding happens asynchronous by default, set this option to 0 to enable synchronous forwards.
If you need the return value of the forwarded job, you have to enable synchronous forwards.

#### worker

Sets the number of workers for synchronous forwards.

### Other Options

#### $logfile

Sets the path to the logfile. Valid options are literal `stdout`, `stderr` or
a path to a logfile.

#### $debug

Enable debug log level.

## Metrics

You can monitor the status of the proxy and fetch some metrics with the `check_gearman` monitoring plugin
from the Mod-Gearman package.

Enable the status queue by putting:

    $statusqueue = "127.0.0.1:4730/proxy_status";

in your configuration and check it with:

    %> .../check_gearman -H localhost -q proxy_status -s check


## License

GearmanProxy is Copyright (c) 2009-2020 by Sven Nierlein.
This is free software; you can redistribute it and/or modify it under the
same terms as the Perl5 programming language system itself.
