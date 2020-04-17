package GearmanProxy;

=head1 NAME

GearmanProxy - forwards jobs in Gearman queues

=cut

use 5.008000;

use warnings;
use strict;
use Gearman::Worker;
use Gearman::Client 2.004;
use threads;
use threads::shared;
use Socket qw(IPPROTO_TCP SOL_SOCKET SO_KEEPALIVE TCP_KEEPIDLE TCP_KEEPINTVL TCP_KEEPCNT);
use POSIX ();
use File::Slurp qw/read_file/;
use Data::Dumper;
use sigtrap 'handler', \&_signal_handler, 'HUP', 'TERM';
use GearmanProxy::Log;

our $VERSION = "2.04";

my $pidFile;
my $max_retries     = 3;   # number of job retries
my $backlog_timeout = 600; # seconds until a job will be removed from the backlog
my %metrics_counter :shared;
my %failed_clients  :shared;
my %backlog         :shared;

#################################################

=head2 new

    GearmanProxy->new({
        configFiles => list of config files
        logFile     => path to logfile or 'stderr', 'stdout'
        pidFile     => optional path to pidfile
        loglevel    => optional flag to set loglevel (0 => errors, 1 => info, 2 => debug, 3 => trace)
    })

=cut
sub new {
    my($class, $config) = @_;

    my $self = {
        args     => $config,
        loglevel => $config->{'loglevel'},
    };
    bless $self, $class;

    return($self);
}

#################################################

=head2 run

    GearmanProxy->run()

=cut
sub run {
    my($self) = @_;

    $pidFile = $self->{'args'}->{'pidFile'};
    GearmanProxy::Log::loglevel($self->{'loglevel'});

    _trace('command line arguments:');
    _trace($self->{'args'});

    #################################################
    # save pid file
    if($pidFile) {
        open(my $fhpid, ">", $pidFile) || die "open ".$pidFile." failed: ".$!;
        print $fhpid $$;
        close($fhpid);
    }

    # unbuffer output
    local $| = 1;

    while(1) {
        $self->_work_loop();
    }

    return(0);
}

#################################################
END {
    unlink($pidFile) if $pidFile;
}

#################################################
sub _signal_handler {
    my($sig) = @_;
    for my $thr (threads->list()) {
        $thr->kill($sig)->detach();
    }
    if($sig eq 'TERM') {
        _info(sprintf("caught signal %s, exiting...", $sig));
        exit(0);
    }
    _info(sprintf("caught signal %s, reloading configuration", $sig));
    return;
}

#################################################
sub _work_loop {
    my($self) = @_;

    $self->_read_config($self->{'args'}->{'configFiles'});
    GearmanProxy::Log::loglevel($self->{'loglevel'});
    GearmanProxy::Log::logfile($self->{'logfile'});
    _capture_standard_output_and_errors($self->{'logfile'});

    _info(sprintf("%s v%s starting...", $0, $VERSION));
    _trace($self->{'queues'});

    if(!defined $self->{'queues'} || scalar keys %{$self->{'queues'}} == 0) {
        _error('no queues configured, exiting');
        exit(3);
    }

    # clear client connection cache and ciphers
    $self->_reset_counter_and_caches();

    # create one worker per uniq server
    for my $server (keys %{$self->{'queues'}}) {
        my $async_queues = {};
        my $sync_queues  = {};
        for my $key (sort keys %{$self->{'queues'}->{$server}}) {
            my $q = $self->{'queues'}->{$server}->{$key};
            if($q->{'async'}) {
                $async_queues->{$key} = $q;
            } else {
                $sync_queues->{$key} = $q;
            }
        }
        if(scalar keys %{$async_queues} > 0) {
            _trace(sprintf("starting single asynchronous worker for %s", $server));
            threads->create('_forward_worker', $self, $server, $async_queues);
        }

        for my $key (sort keys %{$sync_queues}) {
            my $q = $sync_queues->{$key};
            for my $x (1..$q->{'worker'}) {
                _trace(sprintf("starting %d/%d synchronous worker for %s", $x, $q->{'worker'}, $key));
                threads->create('_forward_worker', $self, $server, { $key => $sync_queues->{$key} });
            }
        }
    }

    # create backlog worker thread
    threads->create('_backlog_worker', $self);

    # create status worker thread
    if($self->{'statusqueue'}) {
        threads->create('_status_worker', $self);
    }

    # wait till worker finish
    while(scalar threads->list() > 0) {
        sleep(5);
    }
    _debug("all worker finished");
    return;
}

#################################################
sub _forward_worker {
    my($self, $server, $queues) = @_;
    _trace("worker thread started");

    my $keep_running = 1;
    while($keep_running) {
        my $worker = Gearman::Worker->new(job_servers => [ $server ]);
        _trace(sprintf("worker created for %s", $server));
        my $errors = 0;
        for my $queue (sort keys %{$queues}) {
            if(!$worker->register_function($queue => sub { $self->_job_handler($queues->{$queue}, @_) } )) {
                _error(sprintf("register queue failed on %s for queue %s", $server, $queue));
                $errors++;
            }
        }

        if(scalar keys %{$queues} == $errors) {
            _error(sprintf("gearman daemon %s seems to be down", $server));
        }

        eval {
            $keep_running = $self->_worker_work($server, $worker);
        };
        _error($@) if $@;
    }
    return(threads->exit());
}

#################################################
sub _status_worker {
    my($self) = @_;
    _trace("status worker thread started");

    my $keep_running = 1;
    my($server, $queue) = split(/\//mx, $self->{'statusqueue'});
    while($keep_running) {
        my $worker = Gearman::Worker->new(job_servers => [ $server ]);
        _trace(sprintf("worker created for %s", $server));
        my $errors = 0;
        if(!$worker->register_function($queue => sub { $self->_status_handler($server, $queue, @_) } )) {
            _error(sprintf("register status queue failed on %s for queue %s", $server, $queue));
            $errors++;
        }

        if($errors) {
            _error(sprintf("gearman daemon %s seems to be down", $server));
        }

        eval {
            $keep_running = $self->_worker_work($server, $worker);
        };
        _error($@) if $@;
    }
    return(threads->exit());
}

#################################################
sub _job_handler {
    my($self, $config, $job) = @_;

    _debug(sprintf('[%s//%s] forwarding %s/%s to %s/%s',
            $config->{'localHost'},
            $job->handle,
            $config->{'localHost'},
            $config->{'localQueue'},
            $config->{'remoteHost'},
            $config->{'remoteQueue'},
    ));
    _trace($config);

    my $data    = $job->arg;
    my $size_in = length($data);

    if($config->{'decrypt'}) {
        # decrypt data with local password
        $data = $self->_decrypt($data, $config->{'decrypt'});
    }
    # run data callback
    if($config->{'data_callback'}) {
        # if not already decrypted, data is still base64 encoded
        if(!$config->{'decrypt'}) {
            $data = MIME::Base64::decode_base64($data);
        }

        $data = &{$config->{'data_callback'}}($data, $job, $config, $self);

        # if data is not going to be encrypted, it needs to be base64
        if(!$config->{'encrypt'}) {
            $data = MIME::Base64::encode_base64($data);
        }
    }
    if($config->{'encrypt'}) {
        # encrypt data with new remote password
        $data = $self->_encrypt($data, $config->{'encrypt'});
    }
    my $size_out = length($data);

    # set metrics
    $metrics_counter{$config->{'localQueue'}.'::jobs'}++;
    $metrics_counter{'total_jobs'}++;
    $metrics_counter{'bytes_in'}  += $size_in;
    $metrics_counter{'bytes_out'} += $size_out;
    $metrics_counter{$config->{'localQueue'}.'::bytes_out'} += $size_out;

    # forward data to remote server
    my $result = $self->_dispatch_task({
                server => $config->{'remoteHost'},
                queue  => $config->{'remoteQueue'},
                data   => $data,
                uniq   => $job->handle,
                async  => $config->{'async'},
    });

    return("job submitted as background task") if $config->{'async'};
    return($result);
}

#################################################
sub _status_handler {
    my($self, $server, $queue, $job) = @_;

    _debug(sprintf('[%s//%s] status request on queue %s',
            $server,
            $job->handle,
            $queue,
    ));

    my $data = $job->arg;
    my $perfdatafilter;
    if($data && $data =~ m/perfdatafilter=(\S+)/mx) {
        ## no critic
        $perfdatafilter = qr($1);
        ## use critic
    }

    # make sure we always have some basic metrics set
    $metrics_counter{'total_jobs'}   += 0;
    $metrics_counter{'bytes_in'}     += 0;
    $metrics_counter{'bytes_out'}    += 0;
    $metrics_counter{'total_errors'} += 0;

    # count queues
    my $queue_nr = 0;
    for my $server (sort keys %{$self->{'queues'}}) {
        for my $queue (sort keys %{$self->{'queues'}->{$server}}) {
            my $queue_name = $self->{'queues'}->{$server}->{$queue}->{'localQueue'};
            if($queue_name) {
                $queue_nr++;
                $metrics_counter{$queue_name.'::jobs'}      += 0;
                $metrics_counter{$queue_name.'::bytes_out'} += 0;
            }
        }
    }

    my($exit, $additional_info, $backlog_nr) = (0, "", 0);
    {
        lock(%backlog);
        $backlog_nr = _count_sub_elements(\%backlog);
    }
    if($backlog_nr > 0) {
        $additional_info .= sprintf(" backlog contains %d jobs.", $backlog_nr);
        $exit = 1;
    }
    my $metrics_gauge = {
        'server'  => scalar keys %{$self->{'queues'}},
        'queues'  => $queue_nr,
        'backlog' => $backlog_nr,
    };

    my $perfdata = "";
    my $merged = {%metrics_counter, %{$metrics_gauge}};
    my $keys = [sort keys %{$merged}];
    # move those with :: at the end
    $keys = [grep(!/::/mx, @{$keys}), grep(/::/mx, @{$keys})];
    for my $key (@{$keys}) {
        if($perfdatafilter && $key !~ $perfdatafilter) { next; }
        if(defined $metrics_counter{$key}) {
            $perfdata .= sprintf(" '%s'=%dc;;;", $key, $metrics_counter{$key});
        }
        if(defined $metrics_gauge->{$key}) {
            $perfdata .= sprintf(" '%s'=%d;;;", $key, $metrics_gauge->{$key});
        }
    }

    my $failed_nr  = scalar keys %failed_clients;
    if($failed_nr > 0) {
        $additional_info = sprintf(" %d server%s failed: %s.",
                            $failed_nr,
                            $failed_nr != 1 ? "s" : "",
                            join(", ", sort keys %failed_clients),
                        );
        $exit = 1;
    }

    return(sprintf("%d:%s - proxy version v%s running.%s|%s",
                $exit,
                _status_name($exit),
                $VERSION,
                $additional_info,
                $perfdata,
    ));
}

#################################################
# $self->_dispatch_task($options)
#
#    $options = {
#       server  => "server name",
#       queue   => "queue name",
#       data    => "payload",
#       uniq    => "optional uniq identifier",
#       backlog => "optional backlog reference",
#       async   => "optional flag to disable asyncronous jobs",
#    }
#
sub _dispatch_task {
    my($self, $options) = @_;
    my $server        = $options->{'server'} or die("no server specified");
    my $queue         = $options->{'queue'}  or die("no queue specified");
    my $data          = $options->{'data'};
    my $uniq          = $options->{'uniq'};
    my $backlog_entry = $options->{'backlog'};
    my $task = Gearman::Task->new($queue, \$data, {
        uniq        => $uniq,
        retry_count => $backlog_entry ? undef : $max_retries,
        on_fail     => sub {
            my($err) = @_;
            $err = "unknown error" unless $err;
            $metrics_counter{'total_errors'}++;
            $failed_clients{$server} = $err;
            if($backlog_entry) {
                # already failed previously, just put it back in the backlog
                _debug(sprintf("retrying job %s for %s/%s still fails", $uniq, $server, $queue));
                {
                    lock %backlog;
                    if(!defined $backlog{$server}) {
                        $backlog{$server} = &share([]);
                    }
                    unshift(@{$backlog{$server}}, $backlog_entry);
                }
            } else {
                _error(sprintf("[%s] forwarding to %s failed: %s", $uniq, $server, $err));
                {
                    lock(%backlog);
                    if(!defined $backlog{$server}) {
                        $backlog{$server} = &share([]);
                    }
                    push @{$backlog{$server}}, shared_clone({
                        time   => time(),
                        server => $server,
                        queue  => $queue,
                        data   => $data,
                        uniq   => $uniq,
                    });
                    _error(sprintf("backlog contains %d jobs for %d servers", _count_sub_elements(\%backlog), scalar keys %backlog));
                }
            }
        },
        on_retry    => sub {
            my($attempt) = @_;
            _debug(sprintf("[%s] forwarding to server %s failed, retying: attempt %d/%d", $uniq, $server, $attempt, $max_retries));
        },
        on_complete => sub {
            delete $failed_clients{$server};
        },
    });
    my $client  = $self->_get_client($server);
    if(!$options->{'async'}) {
        my $result = $client->do_task($task);
        return($result);
    }
    my $job_handle = $client->dispatch_background($task);
    if($job_handle) {
        _trace(sprintf("[%s] background job dispatched from %s", $job_handle, $uniq));
        delete $failed_clients{$server};
    } else {
        _debug(sprintf("[%s] background job dispatching failed for %s", $uniq, $server));
    }
    return($job_handle);
}

#################################################
sub _worker_work {
    my($self, $server, $worker) = @_;
    _trace(sprintf("[%s] worker thread starting", $server));

    my $start = time();
    my $keep_running = 1;
    local $SIG{'HUP'}  = sub {
        _debug(sprintf("worker thread exits by signal %s", "HUP"));
        $worker->reset_abilities() if $worker;
        $keep_running = 0;
    };

    _enable_tcp_keepalive($worker);

    $worker->work(
        on_start => sub {
            my($jobhandle) = @_;
            _trace(sprintf("[%s] worker:on_start", $jobhandle));
        },
        on_complete => sub {
            my($jobhandle, $result) = @_;
            my $data = ref $result ? Dumper($result) : $result;
            _trace(sprintf("[%s] worker:on_complete: %s", $jobhandle, $data));
        },
        on_fail => sub {
            my($jobhandle, $err) = @_;
            $err = "unknown worker error" unless $err;
            _error(sprintf("[%s] worker:on_fail: %s", $jobhandle, $err));
        },
        stop_if => sub {
            my($is_idle, $last_job_time) = @_;
            _trace(sprintf("[%s] worker:stop_if: is_idle=%d - last_job_time=%s - keep_running=%s", $server, $is_idle, $last_job_time ? $last_job_time : "never", $keep_running));
            return 1 if ! $keep_running;
            if((!$last_job_time && $start < time() - 60) || ($last_job_time && $last_job_time < time() - 60)) {
                _debug(sprintf("[%s] refreshing worker after 1min idle", $server));
                return 1;
            }
            return;
        },
    );
    _trace(sprintf("[%s] worker thread finished", $server));
    return($keep_running);
}

#################################################
sub _backlog_worker {
    my($self) = @_;
    _trace("backlog worker thread started");

    # clean backlog from none-existing client servers
    my $existing_clients = {};
    for my $s (sort keys %{$self->{'queues'}}) {
        for my $q (sort values %{$self->{'queues'}->{$s}}) {
            my $server = $q->{'remoteHost'};
            next unless $server;
            $existing_clients->{$server} = 1;
        }
    }
    {
        lock(%backlog);
        for my $s (sort keys %backlog) {
            delete $backlog{$s} unless $existing_clients->{$s};
        }
    }

    my $keep_running = 1;
    local $SIG{'HUP'}  = sub {
        _debug(sprintf("backlog worker thread exits by signal %s", "HUP"));
        $keep_running = 0;
    };

    while($keep_running) {
        my($count, $server) = (0, []);
        {
            lock %backlog;
            $count  = scalar keys %backlog;
            $server = [sort keys %backlog];
        }
        if($count == 0) {
            sleep 1;
            next;
        }

        # retry failed jobs
        for my $s (@{$server}) {
            while(1) {
                my $job;
                {
                    lock %backlog;
                    last unless $backlog{$s};
                    $job = shift @{$backlog{$s}};
                    if(!$job) {
                        delete $backlog{$s};
                    }
                }
                last unless $job;
                if($job->{'time'} < time() - $backlog_timeout) {
                    _debug(sprintf("discarding job %s for %s/%s, backlog timeout reached, trying since: %s", $job->{'uniq'}, $job->{'server'}, $job->{'queue'}, scalar localtime $job->{'time'}));
                    next;
                }
                _debug(sprintf("retrying job %s for %s/%s", $job->{'uniq'}, $job->{'server'}, $job->{'queue'}));
                if($self->_dispatch_task({ server  => $job->{'server'},
                                           queue   => $job->{'queue'},
                                           data    => $job->{'data'},
                                           uniq    => $job->{'uniq'},
                                           backlog =>  $job,
                                        })) {
                    _debug(sprintf("retrying job %s for %s/%s finally worked", $job->{'uniq'}, $job->{'server'}, $job->{'queue'}));
                } else {
                    # still failed, it does not make sense to try more from this server
                    last;
                }
            }
        }
        sleep(15);
    }
    return(threads->exit());
}

#################################################
sub _enable_tcp_keepalive {
    my($gearman_obj) = @_;

    # set tcp keepalive for our worker
    if($gearman_obj->{'sock_cache'}) {
        for my $sock (values %{$gearman_obj->{'sock_cache'}}) {
            setsockopt($sock, SOL_SOCKET,  SO_KEEPALIVE,   1);
            setsockopt($sock, IPPROTO_TCP, TCP_KEEPIDLE,  10); # The time (in seconds) the connection needs to remain idle before TCP starts sending keepalive probes
            setsockopt($sock, IPPROTO_TCP, TCP_KEEPINTVL,  5); # The time (in seconds) between individual keepalive probes.
            setsockopt($sock, IPPROTO_TCP, TCP_KEEPCNT,    3); # The maximum number of keepalive probes TCP should send before dropping the connection
        }
    } else {
        _error("failed to set tcp keepalive");
    }
    return;
}

#################################################
sub _read_config {
    my($self, $files) = @_;

    # these variables can be overriden by the config files
    our $queues      = {};
    our $logfile     = "";
    our $debug       = 0;
    our $statusqueue = "";

    for my $entry (@{$files}) {
        my @files;
        if(-d $entry) {
            @files = glob($entry.'/*.{cfg,conf}');
        } else {
            @files = glob($entry);
        }
        for my $file (@files) {
            if(! -r $file) {
                _fatal("ERROR: cannot read: ".$file.": ".$!);
            }

            _debug("reading config file ".$file);
            do "$file";
        }
    }

    $self->{'logfile'}     = $self->{'args'}->{'logFile'} // $logfile // 'stdout';
    $self->{'loglevel'}    = $self->{'args'}->{'debug'} // $debug // 1;
    $self->{'queues'}      = $self->_parse_queues($queues);
    $self->{'statusqueue'} = $statusqueue;

    return;
}

#################################################
# catch prints when not attached to a terminal and redirect them to our logger
sub _capture_standard_output_and_errors {
    my($logfile) = @_;
    if(!$logfile || $logfile eq '-' || lc($logfile) eq 'stdout') {
        return;
    }
    if(lc($logfile) eq 'stderr') {
        return;
    }
    my($tmp, $capture);
    open($capture, '>', \$tmp) or die("cannot open stdout capture: $!");
    ## no critic
    tie *$capture, 'GearmanProxy::Log', (*STDOUT, *STDERR);
    select $capture;

    $SIG{__WARN__} = sub {
        my($message) = @_;
        _error($message);
    };
    $SIG{__DIE__} = sub {
        my($message) = @_;
        _fatal($message);
    };
    *STDERR = *$capture;
    *STDOUT = *$capture;
    ## use critic

    return;
}

#################################################
sub _parse_queues {
    my($self, $raw) = @_;
    my $queues = {};
    for my $key (sort keys %{$raw}) {
        my($fromserver,$fromqueue) = split(/\//mx, $key, 2);
        my $to = $raw->{$key};
        # simple string declaration
        if(ref $to eq '') {
            $to = {
                "remoteQueue" => "$to",
            };
        }
        if(!$to->{'remoteQueue'}) {
            _error("missing remoteQueue definition in queue configuration");
            _error($to);
            next;
        }
        # expand remote host
        my($remoteHost, $remoteQueue) = split(/\//mx, $to->{'remoteQueue'}, 2);
        $to->{'remoteHost'}  = $remoteHost;
        $to->{'remoteQueue'} = $remoteQueue;
        $to->{'localHost'}   = $fromserver;
        $to->{'localQueue'}  = $fromqueue;

        # check crypto modules
        if($to->{'encrypt'} || $to->{'decrypt'}) {
            eval {
                require Crypt::Rijndael;
                require MIME::Base64;
            };
            my $err = $@;
            if($err) {
                _fatal(sprintf("encrypt/decrypt requires additional modules (Crypt::Rijndael and MIME::Base64) which failed to load: %s", $err));
            }
        }

        # set some defaults
        $to->{'async'}  = $to->{'async'}  // 1;
        $to->{'worker'} = $to->{'worker'} // 1;

        $queues->{$fromserver}->{$fromqueue} = $to;
    }
    return($queues);
}

#################################################
sub _encrypt {
    my($self, $txt, $pass) = @_;
    my $cipher = $self->_cipher($pass);
    $txt = _null_pad($txt);
    return(MIME::Base64::encode_base64($cipher->encrypt($txt)));
}

#################################################
sub _decrypt {
    my($self, $txt, $pass) = @_;
    my $cipher = $self->_cipher($pass);
    my $dec = $cipher->decrypt(MIME::Base64::decode_base64($txt));
    # strip null bytes
    $dec =~ s/\x00*$//mx;
    return($dec);
}

#################################################
sub _cipher {
    my($self, $pass) = @_;
    return($self->{'cipher_cache'}->{$pass} ||= do {
        if($pass =~ m/^file:(.*)$/mx) {
            chomp($pass = read_file($1));
        }
        my $key = substr(_null_pad($pass),0,32);
        Crypt::Rijndael->new($key, Crypt::Rijndael::MODE_ECB());
    });
}

#################################################
sub _null_pad {
    my($str) = @_;
    my $pad = (POSIX::ceil(length($str) / 32) * 32) - length($str);
    if(length($str) == 0) { $pad = 32; }
    $str = $str . chr(0) x $pad;
    return($str);
}

#################################################
sub _get_client {
    my($self, $server) = @_;
    return($self->{'clients_cache'}->{$server} ||= do {
        my $client = Gearman::Client->new(job_servers => [$server]);
        _enable_tcp_keepalive($client);
        $client;
    });
}

#################################################
# clear client connection cache and ciphers
sub _reset_counter_and_caches {
    my($self) = @_;
    $self->{'clients_cache'} = {};
    $self->{'cipher_cache'}  = {};
    for my $key (sort keys %metrics_counter) {
        delete $metrics_counter{$key};
    }
    return;
}

#################################################
# count all elements in hash of hashes
sub _count_sub_elements {
    my($el) = @_;
    my $count = 0;
    for my $s (keys %{$el}) {
        if(ref $el->{$s} eq 'HASH') {
            $count += scalar keys %{$el->{$s}};
        }
        elsif(ref $el->{$s} eq 'ARRAY') {
            $count += scalar @{$el->{$s}};
        }
    }
    return($count);
}

#################################################
sub _status_name {
    my($status) = @_;
    if($status == 0) { return("OK"); }
    if($status == 1) { return("WARNING"); }
    if($status == 2) { return("CRITICAL"); }
    return("UNKNOWN");
}

#################################################
sub _fatal { return GearmanProxy::Log::fatal(@_);}
sub _error { return GearmanProxy::Log::error(@_);}
sub _info  { return GearmanProxy::Log::info(@_);}
sub _debug { return GearmanProxy::Log::debug(@_);}
sub _trace { return GearmanProxy::Log::trace(@_);}

#################################################

=head1 AUTHOR

Sven Nierlein, 2009-present, <sven@nierlein.org>

=head1 LICENSE

GearmanProxy is Copyright (c) 2009-2020 by Sven Nierlein.
This is free software; you can redistribute it and/or modify it under the
same terms as the Perl5 programming language system itself.

=cut

1;
